-- ============================================================================
-- Marketplace redesign · Stage 1b — derived pending/available credit.
-- (Run AFTER 0032 so the new enum values exist.)
--
-- Credit is no longer a stored lump on consultant_profiles that grows at delivery.
-- It's DERIVED from the consultant's jobs:
--   available = confirmed  OR  delivered & past the auto-confirm window,
--               and not yet cashed out            → cashable now
--   pending   = delivered & still inside the window → awaiting the user
-- A dispute/revision freezes a job's credit (counts as neither) until resolved.
--
-- This makes the 7-day auto-confirm work with NO cron: the window is evaluated
-- at read time (balance display + cash-out). Cash-out stamps cashout_id on the
-- jobs it pays so the same credit can't be drawn twice.
-- ============================================================================

alter table marketplace_jobs add column if not exists delivered_at timestamptz;
alter table marketplace_jobs add column if not exists confirmed_at timestamptz;
alter table marketplace_jobs add column if not exists cashout_id  uuid references cashout_requests(id) on delete set null;

insert into app_config (key, value) values ('marketplace_autoconfirm_days', '7')
  on conflict (key) do nothing;

-- ── Derived balances ─────────────────────────────────────────────────────────
create or replace function consultant_available_credit(p_user uuid default auth.uid())
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(credit_cents), 0)::int
    from marketplace_jobs
   where consultant_id = coalesce(p_user, auth.uid())
     and cashout_id is null
     and ( state = 'confirmed'
        or ( state = 'delivered'
             and delivered_at <= now() - make_interval(days =>
                   coalesce((select value::int from app_config where key='marketplace_autoconfirm_days'), 7)) ) );
$$;

create or replace function consultant_pending_credit(p_user uuid default auth.uid())
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(credit_cents), 0)::int
    from marketplace_jobs
   where consultant_id = coalesce(p_user, auth.uid())
     and cashout_id is null
     and state = 'delivered'
     and delivered_at > now() - make_interval(days =>
           coalesce((select value::int from app_config where key='marketplace_autoconfirm_days'), 7));
$$;
grant execute on function consultant_available_credit(uuid) to authenticated;
grant execute on function consultant_pending_credit(uuid)   to authenticated;

-- ── Cash-out now draws COMPUTED available credit and tags the jobs it paid ────
create or replace function request_cashout()
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_avail int; v_min int; v_win int; v_cashout uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from consultant_profiles where user_id = v_user) then
    raise exception 'not a consultant';
  end if;
  select coalesce((select value::int from app_config where key='consultant_cashout_min_cents'), 5000) into v_min;
  select coalesce((select value::int from app_config where key='marketplace_autoconfirm_days'), 7)   into v_win;
  v_avail := consultant_available_credit(v_user);
  if v_avail < v_min then
    raise exception 'balance below the % minimum', to_char(v_min/100.0, 'FM990.00');
  end if;

  insert into cashout_requests (consultant_id, amount_cents) values (v_user, v_avail) returning id into v_cashout;
  update marketplace_jobs set cashout_id = v_cashout
   where consultant_id = v_user and cashout_id is null
     and ( state = 'confirmed'
        or ( state = 'delivered' and delivered_at <= now() - make_interval(days => v_win) ) );

  insert into notifications (user_id, type, title, body, data)
    select id, 'cashout_requested', 'Cash-out requested',
           'A consultant requested a $' || to_char(v_avail/100.0, 'FM999990.00') || ' cash-out.', '{}'::jsonb
      from users where role = 'platform_admin';
end $$;
grant execute on function request_cashout() to authenticated;

-- ── Backfill: existing 'delivered' jobs came from the OLD admin-vetted flow, so
-- treat them as already confirmed (credit earned) with a delivered_at timestamp.
update marketplace_jobs
   set state = 'confirmed',
       confirmed_at = coalesce(confirmed_at, updated_at, now()),
       delivered_at = coalesce(delivered_at, updated_at, now())
 where state = 'delivered';

-- Credit is derived from jobs now, so retire the stored lump to avoid double count.
update consultant_profiles set credit_balance_cents = 0, updated_at = now()
 where credit_balance_cents <> 0;

notify pgrst, 'reload schema';
