-- ============================================================================
-- Marketplace v1 · Phase 1 — claim + two-track pricing state machine.
--
-- Drives the whole loop: a rejected fix (👎) posts a job + notifies module-matched
-- consultants → a consultant accepts at $4.99 (Track A) or proposes a higher price
-- (Track B, capped) → the user approves + pays any delta → consultant submits a
-- fix (into the review queue) → admin delivers it (updates the user's resolution +
-- credits the consultant's ledger). The end user never sees a "marketplace"
-- (scope 13.6): to them it's "a specialist is on it" / "a price came back".
-- The delta CHARGE itself is a proxy endpoint (Phase 1b); these RPCs move state.
-- ============================================================================

-- Deliver the consultant's verified fix WITHOUT overwriting the immutable original
-- snapshot (8.1). "My fixes" prefers verified_steps when present.
alter table resolutions      add column if not exists verified_steps jsonb;
alter table marketplace_jobs add column if not exists solution_id    uuid references solutions(id) on delete set null;

-- ── Entry point: 👎 now also posts a marketplace job + pings consultants ──────
create or replace function escalate_resolution(p_resolution_id uuid, p_context text)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype; v_module text; v_job uuid;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions where id = p_resolution_id and user_id = v_user for update;
  if not found then raise exception 'resolution not found'; end if;
  if r.state not in ('matched_unlocked', 'resolved_confirmed') then
    raise exception 'only a revealed resolution can be escalated';
  end if;

  update resolutions set outcome='down', state='escalated',
         activity = nullif(btrim(coalesce(p_context,'')),''), updated_at=now()
   where id = p_resolution_id;
  if r.solution_id is not null then
    update solutions set times_rejected = times_rejected + 1 where id = r.solution_id;
    select component_name into v_module from solutions where id = r.solution_id;
  end if;

  -- Post to the queue (idempotent) and notify approved, module-matched consultants.
  v_job := create_marketplace_job(p_resolution_id, v_module);
  insert into notifications (user_id, type, title, body, data)
    select cp.user_id, 'job_available',
           'New job' || coalesce(' · ' || v_module, ''),
           'A user needs help with an IFS error — one-tap accept at $4.99.',
           jsonb_build_object('job_id', v_job, 'module', v_module)
      from consultant_profiles cp
     where cp.status = 'approved' and (v_module is null or v_module = any(cp.modules));
end $$;

-- ── Guards ───────────────────────────────────────────────────────────────────
create or replace function _consultant_can_take(p_user uuid, p_module text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from consultant_profiles
    where user_id = p_user and status = 'approved'
      and (p_module is null or p_module = any(modules)));
$$;

-- ── Track A: accept at base price, start immediately ─────────────────────────
create or replace function accept_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_days int; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if not _consultant_can_take(v_user, j.module) then raise exception 'not eligible for this job'; end if;
  if j.state <> 'open' then raise exception 'job is no longer open'; end if;
  select coalesce((select value::int from app_config where key='marketplace_sla_days'), 7) into v_days;
  update marketplace_jobs
     set consultant_id=v_user, state='in_progress', claimed_at=now(),
         deadline_at = now() + make_interval(days => v_days), updated_at=now()
   where id = p_job_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'in_progress','A specialist is on it',
            'A specialist picked up your issue and is working on a fix.',
            jsonb_build_object('job_id', p_job_id));
end $$;

-- ── Track B: propose a higher price (capped), awaiting the user's approval ────
create or replace function propose_job_price(p_job_id uuid, p_price_cents int)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_days int; v_cap_mult int; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if not _consultant_can_take(v_user, j.module) then raise exception 'not eligible for this job'; end if;
  if j.state <> 'open' then raise exception 'job is no longer open'; end if;
  select coalesce((select value::int from app_config where key='trackb_cap_multiplier'), 5) into v_cap_mult;
  if p_price_cents < j.base_price_cents or p_price_cents > j.base_price_cents * v_cap_mult then
    raise exception 'proposed price out of allowed range';
  end if;
  select coalesce((select value::int from app_config where key='marketplace_sla_days'), 7) into v_days;
  update marketplace_jobs
     set consultant_id=v_user, proposed_price_cents=p_price_cents, state='price_proposed',
         claimed_at=now(), deadline_at = now() + make_interval(days => v_days), updated_at=now()
   where id = p_job_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'price_proposed','A price came back for your issue',
            'A specialist can take this for $' || to_char(p_price_cents/100.0,'FM999990.00') || '. Approve to proceed.',
            jsonb_build_object('job_id', p_job_id, 'price_cents', p_price_cents));
end $$;

-- ── User responds to a proposed price ────────────────────────────────────────
-- Accept → 'awaiting_payment' (the delta is charged via the Phase 1b endpoint,
-- which then advances to in_progress). Decline → reopen at base for another
-- consultant (Track A still possible); if it then lapses, the Phase 2 timer refunds.
create or replace function respond_to_price(p_job_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner <> v_user then raise exception 'not your job'; end if;
  if j.state <> 'price_proposed' then raise exception 'no price to respond to'; end if;

  if p_accept then
    update marketplace_jobs set state='awaiting_payment', updated_at=now() where id=p_job_id;
  else
    if j.consultant_id is not null then
      insert into notifications(user_id,type,title,body,data)
        values (j.consultant_id,'price_declined','Price declined',
                'The user declined your proposed price; the job is back in the queue.',
                jsonb_build_object('job_id', p_job_id));
    end if;
    update marketplace_jobs set state='open', consultant_id=null, proposed_price_cents=null,
           deadline_at=null, updated_at=now() where id=p_job_id;
  end if;
end $$;

-- ── Consultant submits their fix → review queue ──────────────────────────────
create or replace function submit_job_fix(p_job_id uuid, p_title text, p_who text, p_steps jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; r resolutions%rowtype; v_sol uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.consultant_id <> v_user then raise exception 'not your job'; end if;
  if j.state <> 'in_progress' then raise exception 'job is not in progress'; end if;
  if p_steps is null or jsonb_array_length(p_steps) = 0 then raise exception 'no steps submitted'; end if;
  select * into r from resolutions where id = j.resolution_id;

  insert into solutions (error_code, component_name, title, who_acts, source, status,
                         instructions, contributed_by_user_id)
    values (r.error_code, j.module, coalesce(p_title, 'Consultant fix for ' || coalesce(r.error_code,'error')),
            p_who, 'CONSULTANT', 'PENDING_REVIEW', p_steps, v_user)
    returning id into v_sol;

  update marketplace_jobs set state='submitted', solution_id=v_sol, updated_at=now() where id=p_job_id;

  insert into notifications(user_id,type,title,body,data)
    select id,'job_submitted','Consultant fix awaiting review',
           'A consultant submitted a fix — review it in the library, then deliver.',
           jsonb_build_object('job_id', p_job_id, 'solution_id', v_sol)
      from users where role='platform_admin';
end $$;

-- ── Admin delivers the reviewed fix → user + consultant credit ───────────────
create or replace function deliver_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; s solutions%rowtype; v_owner uuid;
        v_tier text; v_split int; v_fee int; v_credit int;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.state <> 'submitted' then raise exception 'job is not awaiting delivery'; end if;
  if j.solution_id is null then raise exception 'no submitted fix on this job'; end if;
  select * into s from solutions where id = j.solution_id;

  -- Deliver to the user: the verified steps show in "My fixes" (original snapshot kept).
  update resolutions set verified_steps = s.instructions, state='resolved_by_consultant', updated_at=now()
   where id = j.resolution_id;

  -- Credit the consultant: tiered % of the fee collected (base + any delta).
  v_fee := coalesce(j.proposed_price_cents, j.base_price_cents);
  select tier into v_tier from consultant_profiles where user_id = j.consultant_id;
  select coalesce((select value::int from app_config
           where key = 'tier_split_' || coalesce(v_tier,'bronze')), 70) into v_split;
  v_credit := (v_fee * v_split) / 100;
  update consultant_profiles set credit_balance_cents = credit_balance_cents + v_credit, updated_at=now()
   where user_id = j.consultant_id;

  update marketplace_jobs set state='delivered', updated_at=now() where id=p_job_id;

  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'delivered','Your verified fix is ready',
            'A specialist resolved your issue — open "My fixes" to view it.',
            jsonb_build_object('job_id', p_job_id));
  insert into notifications(user_id,type,title,body,data)
    values (j.consultant_id,'job_paid','Job delivered — credit added',
            'Your fix was delivered. $' || to_char(v_credit/100.0,'FM999990.00') || ' added to your balance.',
            jsonb_build_object('job_id', p_job_id, 'credit_cents', v_credit));
end $$;

-- ── Admin closes a failed job (→ refund; the Stripe refund is manual as today) ─
create or replace function admin_close_job(p_job_id uuid, p_refunded boolean)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; v_owner uuid;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  update marketplace_jobs set state = case when p_refunded then 'refunded' else 'rejected' end,
         updated_at=now() where id=p_job_id;
  update resolutions set state = case when p_refunded then 'refunded' else 'resolved_disputed' end,
         updated_at=now() where id = j.resolution_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner, case when p_refunded then 'refunded' else 'job_closed' end,
            case when p_refunded then 'Refund issued' else 'Update on your issue' end,
            case when p_refunded then 'We couldn''t deliver a verified fix, so your payment has been refunded.'
                 else 'A specialist could not resolve this one — our team is following up.' end,
            jsonb_build_object('job_id', p_job_id));
end $$;

grant execute on function accept_job(uuid)                    to authenticated;
grant execute on function propose_job_price(uuid, int)        to authenticated;
grant execute on function respond_to_price(uuid, boolean)     to authenticated;
grant execute on function submit_job_fix(uuid, text, text, jsonb) to authenticated;
grant execute on function deliver_job(uuid)                   to authenticated;
grant execute on function admin_close_job(uuid, boolean)      to authenticated;
-- _consultant_can_take is a helper; grant so the definer RPCs can call it uniformly.
grant execute on function _consultant_can_take(uuid, text)    to authenticated;

-- ── "My fixes" now prefers a delivered consultant fix over the original snapshot ─
create or replace function my_resolutions()
returns table (
  id uuid, created_at timestamptz, state resolution_state, outcome text,
  error_code text, error_text text, screen_name text, price_cents int,
  solution_title text, who_acts text, steps jsonb
)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select r.id, r.created_at, r.state, r.outcome,
           r.error_code, r.error_text, r.screen_name, r.price_cents,
           s.title, s.who_acts, coalesce(r.verified_steps, r.steps_snapshot)
      from resolutions r
      left join solutions s on s.id = r.solution_id
     where r.user_id = v_user
       and coalesce(r.verified_steps, r.steps_snapshot) is not null
       and r.state <> 'refunded'
     order by r.created_at desc;
end $$;
grant execute on function my_resolutions() to authenticated;
