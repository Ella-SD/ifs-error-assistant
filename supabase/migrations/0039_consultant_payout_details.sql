-- ============================================================================
-- Consultant payout details.
--
-- Cash-outs are paid off-platform (e-transfer/PayPal/etc.), but the app never
-- collected WHERE to send the money. This adds a free-text payout field the
-- consultant fills in, requires it before a cash-out can be requested, and
-- surfaces it to the admin on the cash-out request.
-- ============================================================================

alter table consultant_profiles add column if not exists payout_details text;

-- Consultant sets/updates their own payout destination.
create or replace function set_payout_details(p_details text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from consultant_profiles where user_id = v_user) then
    raise exception 'not a consultant';
  end if;
  update consultant_profiles
     set payout_details = nullif(btrim(coalesce(p_details, '')), ''), updated_at = now()
   where user_id = v_user;
end $$;
grant execute on function set_payout_details(text) to authenticated;

-- request_cashout now refuses if no payout details are on file (body change only).
create or replace function request_cashout()
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_avail int; v_min int; v_win int; v_cashout uuid; v_payout text;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select payout_details into v_payout from consultant_profiles where user_id = v_user;
  if not found then raise exception 'not a consultant'; end if;
  if nullif(btrim(coalesce(v_payout, '')), '') is null then
    raise exception 'Add your payout details before requesting a cash-out.';
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

-- admin_cashouts: add payout_details (return columns change → drop first).
drop function if exists admin_cashouts();
create or replace function admin_cashouts()
returns table (id uuid, consultant_email text, payout_details text, amount_cents int, status text, requested_at timestamptz, paid_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select c.id, u.email, cp.payout_details, c.amount_cents, c.status, c.requested_at, c.paid_at
      from cashout_requests c
      join users u on u.id = c.consultant_id
      left join consultant_profiles cp on cp.user_id = c.consultant_id
     order by (c.status = 'requested') desc, c.requested_at desc;
end $$;
grant execute on function admin_cashouts() to authenticated;
