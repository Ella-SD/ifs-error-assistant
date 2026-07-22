-- ============================================================================
-- Marketplace v1 · Phase 0 — the claim/negotiation state machine.
--
-- One job per resolution that goes to a consultant. The END USER never sees a
-- "marketplace" (scope 13.6): from their side a job just means "a price/answer
-- will come back to approve". Consultants work reactively (notified of matching-
-- module jobs); the queue is a backup. Writes go through SECURITY DEFINER RPCs
-- (claim / propose-price / submit — Phase 1); Phase 0 defines the table, RLS
-- reads, and the entry-point create RPC.
-- ============================================================================

do $$ begin
  if not exists (select 1 from pg_type where typname = 'job_state') then
    create type job_state as enum (
      'open',              -- posted, waiting for a consultant
      'claimed',           -- taken at base price (Track A) → in progress
      'price_proposed',    -- consultant proposed a higher price (Track B), awaiting user
      'awaiting_payment',  -- user accepted the price, delta payment pending
      'in_progress',       -- paid/started, consultant working
      'submitted',         -- consultant submitted a fix (into the review queue)
      'delivered',         -- reviewed + delivered to the user
      'rejected',          -- review rejected / consultant failed
      'refunded',          -- refunded to the user
      'reopened',          -- returned to the queue (decline)
      'expired'            -- no response within the window
    );
  end if;
end $$;

create table if not exists marketplace_jobs (
  id                    uuid primary key default gen_random_uuid(),
  resolution_id         uuid not null references resolutions(id) on delete cascade,
  module                text,                      -- routing key (catalog COMPONENT_NAME)
  state                 job_state not null default 'open',
  consultant_id         uuid references users(id) on delete set null,
  base_price_cents      int not null default 499,
  proposed_price_cents  int,                       -- Track B ask (capped in the RPC)
  delta_payment_intent  text,
  claimed_at            timestamptz,
  deadline_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index if not exists mjobs_state_idx      on marketplace_jobs(state);
create index if not exists mjobs_module_idx     on marketplace_jobs(module);
create index if not exists mjobs_consultant_idx on marketplace_jobs(consultant_id);
create index if not exists mjobs_resolution_idx on marketplace_jobs(resolution_id);

alter table marketplace_jobs enable row level security;
-- Reads: the originating user (owns the resolution), the assigned consultant, an
-- approved consultant seeing OPEN jobs in one of their modules, or platform_admin.
create policy mjobs_read on marketplace_jobs for select using (
  is_platform_admin()
  or consultant_id = auth.uid()
  or exists (select 1 from resolutions r where r.id = resolution_id and r.user_id = auth.uid())
  or (state = 'open' and exists (
        select 1 from consultant_profiles cp
        where cp.user_id = auth.uid() and cp.status = 'approved'
          and marketplace_jobs.module = any (cp.modules)))
);

-- Post a resolution to the queue (entry point). Idempotent — an active job for the
-- same resolution is returned rather than duplicated.
create or replace function create_marketplace_job(p_resolution_id uuid, p_module text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype; v_id uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions
    where id = p_resolution_id and (user_id = v_user or is_platform_admin());
  if not found then raise exception 'resolution not found'; end if;

  select id into v_id from marketplace_jobs
    where resolution_id = p_resolution_id
      and state not in ('delivered','rejected','refunded','expired')
    limit 1;
  if v_id is not null then return v_id; end if;   -- already queued

  insert into marketplace_jobs (resolution_id, module, state)
    values (p_resolution_id, p_module, 'open')
    returning id into v_id;
  return v_id;
end $$;

grant execute on function create_marketplace_job(uuid, text) to authenticated;
