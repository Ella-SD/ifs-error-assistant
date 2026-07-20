-- ============================================================================
-- Phase 2 · Billing — Stripe subscription + pay-as-you-go columns
--
-- Adds billing state to companies (the $299 company plan) and users (the $49
-- personal plan and $15 pay-as-you-go). These columns are the source of truth
-- for access, and are written ONLY by the Stripe webhook (via the service_role
-- key, which bypasses RLS). Clients must never be able to grant themselves
-- access, so table-level UPDATE is replaced with column-scoped UPDATE that
-- excludes every billing column (see the grants block).
--
-- Additive + idempotent.
-- ============================================================================

-- ── companies (company plan) ────────────────────────────────────────────────
alter table companies
  add column if not exists stripe_customer_id     text,
  add column if not exists stripe_subscription_id text,
  add column if not exists plan                    text,   -- 'company' | null
  add column if not exists subscription_status     text,   -- Stripe status verbatim
  add column if not exists current_period_end      timestamptz;

alter table companies drop constraint if exists companies_plan_check;
alter table companies add constraint companies_plan_check
  check (plan is null or plan = 'company');

create index if not exists companies_stripe_customer_idx on companies(stripe_customer_id);

-- ── users (personal plan / pay-as-you-go) ───────────────────────────────────
alter table users
  add column if not exists stripe_customer_id     text,
  add column if not exists stripe_subscription_id text,
  add column if not exists plan                    text,   -- 'personal' | 'pay_as_you_go' | null
  add column if not exists subscription_status     text,
  add column if not exists current_period_end      timestamptz,
  add column if not exists payg_ready              boolean not null default false;  -- a card is saved for per-use charges

alter table users drop constraint if exists users_plan_check;
alter table users add constraint users_plan_check
  check (plan is null or plan in ('personal', 'pay_as_you_go'));

create index if not exists users_stripe_customer_idx on users(stripe_customer_id);

-- ── Lock billing columns away from client writes ────────────────────────────
-- RLS decides WHICH rows a client may update; column privileges decide WHICH
-- columns. Without this, a company_admin could POST subscription_status='active'
-- straight to their own company row and bypass payment entirely. So drop the
-- blanket table UPDATE and re-grant only the genuinely client-editable columns.
-- (service_role bypasses all of this; the webhook uses it.)
revoke update on companies from authenticated;
grant  update (name, ifs_version) on companies to authenticated;

revoke update on users from authenticated;
grant  update (role) on users to authenticated;

-- ── Access helper ───────────────────────────────────────────────────────────
-- True when the user has an active subscription — personally OR via their
-- company. (Pay-as-you-go is NOT blanket access; it's charged per resolution and
-- checked separately.) 'trialing' counts as active in case a trial is added later.
create or replace function has_active_subscription(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from users u
    left join companies c on c.id = u.company_id
    where u.id = p_user_id
      and (
        u.subscription_status in ('active', 'trialing')
        or c.subscription_status in ('active', 'trialing')
      )
  );
$$;

grant execute on function has_active_subscription(uuid) to authenticated, service_role;
