-- ============================================================================
-- Marketplace v1 · consultant credit cash-out — deliberately LEAN + MANUAL.
--
-- No Stripe Connect (deferred). A consultant with a balance at/above the
-- configured minimum requests a cash-out; that snapshots the balance into a
-- request row and zeroes the ledger (so they can't request the same credit
-- twice). An admin pays them off-platform (bank/PayPal) and marks it paid. This
-- mirrors the lean/manual pattern used for refunds + escalation elsewhere.
-- ============================================================================

create table if not exists cashout_requests (
  id            uuid primary key default gen_random_uuid(),
  consultant_id uuid not null references users(id) on delete cascade,
  amount_cents  int  not null,
  status        text not null default 'requested',   -- requested | paid
  requested_at  timestamptz not null default now(),
  paid_at       timestamptz
);
create index if not exists cashout_consultant_idx on cashout_requests(consultant_id);

alter table cashout_requests enable row level security;
-- A consultant reads their own requests; admin reads all (via the RPC). Writes
-- only through the SECURITY DEFINER RPCs below.
create policy cashout_own_read on cashout_requests for select
  using (consultant_id = auth.uid() or is_platform_admin());

-- Consultant requests a cash-out of their full current balance.
create or replace function request_cashout()
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_bal int; v_min int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select credit_balance_cents into v_bal from consultant_profiles where user_id = v_user for update;
  if v_bal is null then raise exception 'not a consultant'; end if;
  select coalesce((select value::int from app_config where key = 'consultant_cashout_min_cents'), 5000) into v_min;
  if v_bal < v_min then
    raise exception 'balance below the % minimum', to_char(v_min/100.0, 'FM990.00');
  end if;

  insert into cashout_requests (consultant_id, amount_cents) values (v_user, v_bal);
  update consultant_profiles set credit_balance_cents = 0, updated_at = now() where user_id = v_user;

  insert into notifications (user_id, type, title, body, data)
    select id, 'cashout_requested', 'Cash-out requested',
           'A consultant requested a $' || to_char(v_bal/100.0, 'FM999990.00') || ' cash-out.', '{}'::jsonb
      from users where role = 'platform_admin';
end $$;

-- Admin lists cash-out requests (pending first).
create or replace function admin_cashouts()
returns table (id uuid, consultant_email text, amount_cents int, status text, requested_at timestamptz, paid_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select c.id, u.email, c.amount_cents, c.status, c.requested_at, c.paid_at
      from cashout_requests c join users u on u.id = c.consultant_id
     order by (c.status = 'requested') desc, c.requested_at desc;
end $$;

-- Admin marks a request paid (after paying off-platform).
create or replace function admin_mark_cashout_paid(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c cashout_requests%rowtype;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into c from cashout_requests where id = p_id for update;
  if not found then raise exception 'request not found'; end if;
  if c.status = 'paid' then return; end if;
  update cashout_requests set status = 'paid', paid_at = now() where id = p_id;
  insert into notifications (user_id, type, title, body, data)
    values (c.consultant_id, 'cashout_paid', 'Cash-out paid',
            'Your $' || to_char(c.amount_cents/100.0, 'FM999990.00') || ' cash-out has been paid.',
            jsonb_build_object('cashout_id', p_id));
end $$;

grant execute on function request_cashout()               to authenticated;
grant execute on function admin_cashouts()                to authenticated;
grant execute on function admin_mark_cashout_paid(uuid)   to authenticated;
