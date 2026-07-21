-- ============================================================================
-- Paid-resolution foundation — resolution state machine + solution versioning +
-- editable config + access-gating RPCs.
--
-- This is ADDITIVE and non-breaking: it adds new tables/columns/functions but
-- does NOT yet lock the solutions.instructions column. That lock (migration
-- 0010) comes LAST, after the app stops reading steps client-side — otherwise it
-- would break the live app mid-rollout.
--
-- Model (per the scope doc, Part 8.7): every resolution is one row moving through
-- a fixed state machine, carrying the solution id + an IMMUTABLE snapshot of the
-- steps shown, the match confidence, the account type at the time, and the
-- thumbs outcome — so archive, refunds, and consultant credit all read from one
-- source of truth.
-- ============================================================================

-- ── Editable config (price, thresholds) ─────────────────────────────────────
create table if not exists app_config (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
insert into app_config(key, value) values ('payg_price_cents', '499')
  on conflict (key) do nothing;

alter table app_config enable row level security;
-- Price isn't secret — any signed-in user may read it (to show the $4.99 preview).
create policy app_config_select on app_config for select using (true);
-- Only platform_admin may change config.
create policy app_config_update on app_config for update
  using (is_platform_admin()) with check (is_platform_admin());

-- ── Solution versioning (for immutable snapshots) ───────────────────────────
alter table solutions add column if not exists version int not null default 1;

-- Bump the version whenever the steps change, so a snapshot can pin an exact one.
create or replace function bump_solution_version()
returns trigger language plpgsql as $$
begin
  if new.instructions is distinct from old.instructions then
    new.version := old.version + 1;
  end if;
  return new;
end $$;
drop trigger if exists solutions_version_trg on solutions;
create trigger solutions_version_trg before update on solutions
  for each row execute function bump_solution_version();

-- ── Resolution state machine ────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_type where typname = 'resolution_state') then
    create type resolution_state as enum
      ('searching','no_match','matched_locked','matched_unlocked','resolved_confirmed','resolved_disputed');
  end if;
end $$;

create table if not exists resolutions (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null references users(id) on delete cascade,
  company_id                  uuid references companies(id) on delete set null,  -- null for personal / PAYG
  error_code                  text,
  error_text                  text,
  screen_name                 text,
  ifs_version_hint            text,
  match_confidence            text,
  account_type_at_resolution  text,   -- 'company' | 'personal' | 'pay_as_you_go' | 'none'
  solution_id                 uuid references solutions(id) on delete set null,
  solution_version            int,
  steps_snapshot              jsonb,  -- immutable copy of the steps as shown
  state                       resolution_state not null default 'searching',
  outcome                     text,   -- 'up' | 'down' | null
  price_cents                 int not null default 0,   -- charged amount (0 for subscribers)
  stripe_payment_intent       text,
  activity                    text,   -- free-text "what were you trying to do" (only on escalation)
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create index if not exists resolutions_user_idx     on resolutions(user_id);
create index if not exists resolutions_company_idx  on resolutions(company_id);
create index if not exists resolutions_solution_idx on resolutions(solution_id);

alter table resolutions enable row level security;
-- A user sees their own resolutions and their company's. No platform_admin escape
-- hatch on the private error data (same posture as the archive).
create policy resolutions_select on resolutions for select
  using (user_id = auth.uid() or company_id = auth_company_id());
-- All writes go through the SECURITY DEFINER RPCs below (no direct client writes).

-- ── RPCs ────────────────────────────────────────────────────────────────────

-- Open a resolution when a user submits an error. Records the match context +
-- the account type, but NEVER the steps. Returns the resolution id.
create or replace function start_resolution(
  p_error_code text, p_error_text text, p_screen_name text,
  p_version_hint text, p_match_confidence text, p_solution_id uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_p users%rowtype; v_acct text; v_id uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into v_p from users where id = v_user;

  if v_p.company_id is not null and exists (
       select 1 from companies c where c.id = v_p.company_id and c.subscription_status in ('active','trialing')) then
    v_acct := 'company';
  elsif v_p.subscription_status in ('active','trialing') then
    v_acct := 'personal';
  elsif v_p.payg_ready then
    v_acct := 'pay_as_you_go';
  else
    v_acct := 'none';
  end if;

  insert into resolutions (user_id, company_id, error_code, error_text, screen_name,
                           ifs_version_hint, match_confidence, account_type_at_resolution,
                           solution_id, state)
    values (v_user, v_p.company_id, p_error_code, p_error_text, p_screen_name,
            p_version_hint, p_match_confidence, v_acct, p_solution_id,
            (case when p_solution_id is null then 'no_match' else 'matched_locked' end)::resolution_state)
    returning id into v_id;
  return v_id;
end $$;

-- SUBSCRIBER reveal — free. Snapshots the steps, transitions to matched_unlocked,
-- counts the serve, and returns the steps. PAYG users are refused here and must
-- go through the paid /api/billing/unlock endpoint instead.
create or replace function reveal_solution(p_resolution_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype; s solutions%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions where id = p_resolution_id and user_id = v_user for update;
  if not found then raise exception 'resolution not found'; end if;
  if r.solution_id is null then raise exception 'no solution to reveal'; end if;

  if not (has_active_subscription(v_user) or is_platform_admin()) then
    raise exception 'payment required';   -- PAYG goes through the unlock endpoint
  end if;

  select * into s from solutions where id = r.solution_id;
  update resolutions
     set state = 'matched_unlocked', solution_version = s.version,
         steps_snapshot = s.instructions, price_cents = 0, updated_at = now()
   where id = p_resolution_id;
  update solutions set times_served = times_served + 1 where id = r.solution_id;

  return jsonb_build_object('title', s.title, 'who_acts', s.who_acts,
                            'steps', s.instructions, 'source', s.source,
                            'sources', s.assembled_sources, 'version', s.version);
end $$;

-- Post-reveal thumbs. Up = the fix worked → counts as a VERIFIED accept (the
-- consultant-credit signal) and can flip PUBLISHED→VERIFIED. Down feeds refunds
-- + quality. One outcome per resolution.
create or replace function record_outcome(p_resolution_id uuid, p_up boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions where id = p_resolution_id and user_id = v_user for update;
  if not found then raise exception 'resolution not found'; end if;

  update resolutions
     set outcome = case when p_up then 'up' else 'down' end,
         state   = (case when p_up then 'resolved_confirmed' else 'resolved_disputed' end)::resolution_state,
         updated_at = now()
   where id = p_resolution_id;

  if r.solution_id is not null then
    if p_up then
      update solutions set times_accepted = times_accepted + 1, last_verified = now(),
             status = case when status = 'PUBLISHED' then 'VERIFIED'::solution_status else status end
       where id = r.solution_id;
    else
      update solutions set times_rejected = times_rejected + 1 where id = r.solution_id;
    end if;
  end if;
end $$;

-- Admin/reviewer read of full solutions incl. steps (end users can't select the
-- instructions column once 0010 locks it; the library-management view uses this).
create or replace function admin_solutions_with_steps()
returns setof solutions
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query select * from solutions order by times_accepted desc, error_code;
end $$;

grant execute on function start_resolution(text,text,text,text,text,uuid) to authenticated;
grant execute on function reveal_solution(uuid)          to authenticated;
grant execute on function record_outcome(uuid,boolean)   to authenticated;
grant execute on function admin_solutions_with_steps()   to authenticated;
