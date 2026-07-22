-- ============================================================================
-- Marketplace v1 · Phase 0 — consultant capability.
--
-- Orthogonal to the company role (a person can be a company_member AND a
-- consultant, per scope 10.2), so this is a SEPARATE table keyed by user_id, not
-- a new value on users.role. A row = the user has applied/been approved as a
-- consultant. `tier` drives the eventual payout split; `status` gates who can
-- claim jobs; `credit_balance_cents` is the earned-but-unpaid balance for the
-- credit-ledger payout model (cash-out is manual for v1 — Stripe Connect deferred).
-- ============================================================================

create table if not exists consultant_profiles (
  user_id                   uuid primary key references users(id) on delete cascade,
  modules                   text[] not null default '{}',   -- specialization: catalog COMPONENT_NAME values
  tier                      text not null default 'bronze',  -- bronze | silver | gold
  status                    text not null default 'pending', -- pending | approved | suspended
  credit_balance_cents      int  not null default 0,          -- earned, not yet cashed out
  stripe_connect_account_id text,                             -- reserved for future Connect; null for now
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

alter table consultant_profiles enable row level security;
-- A user reads their own profile; platform_admin reads all. No direct writes —
-- all mutations go through the SECURITY DEFINER RPCs below.
create policy consultant_self_read on consultant_profiles for select
  using (user_id = auth.uid() or is_platform_admin());

-- Helper used by job RLS: is the caller an APPROVED consultant?
create or replace function is_approved_consultant(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from consultant_profiles
    where user_id = coalesce(p_user, auth.uid()) and status = 'approved'
  );
$$;

-- Self-serve application (light-touch vetting; lands in 'pending' for admin approval).
create or replace function apply_as_consultant(p_modules text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  insert into consultant_profiles (user_id, modules, status)
    values (v_user, coalesce(p_modules, '{}'), 'pending')
  on conflict (user_id) do update
    set modules = excluded.modules, updated_at = now();
end $$;

-- Admin approves / suspends / re-tiers a consultant.
create or replace function admin_set_consultant(p_user uuid, p_status text, p_tier text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  update consultant_profiles
     set status = coalesce(p_status, status),
         tier   = coalesce(p_tier, tier),
         updated_at = now()
   where user_id = p_user;
end $$;

grant execute on function is_approved_consultant(uuid)          to authenticated;
grant execute on function apply_as_consultant(text[])           to authenticated;
grant execute on function admin_set_consultant(uuid, text, text) to authenticated;
