-- ============================================================================
-- Quote-first pricing (supersedes the one-tap $4.99 Track A model).
--
-- Decision (product review, 2026-07): the subscription covers the library +
-- assembly but NO human work. Every escalation goes to an IFS specialist who
-- sends a QUOTE; nobody is charged until the user approves that quote. There is
-- no longer a flat one-tap accept.
--
--   * $10 floor / $200 ceiling  (base 1000, cap multiplier 20).
--   * base price is now config-driven (marketplace_base_price_cents).
--   * accept_job is retired — it raises, so no path can silently start an
--     unpaid job. Specialists use propose_job_price only.
--   * escalate_resolution copy drops the "$4.99 one-tap" framing.
--   * job_open_timeout_hours drives the client's "still finding a specialist"
--     fallback so an unquoted job never just hangs silently.
--   * (The Stripe refund itself is issued by the new consultant-refund proxy
--     endpoint; admin_close_job from 0027 still reverses the consultant credit.)
-- ============================================================================

-- ── Config: floor, ceiling, no-specialist fallback window ────────────────────
insert into app_config(key, value) values ('marketplace_base_price_cents', '1000')
  on conflict (key) do update set value = excluded.value;
insert into app_config(key, value) values ('trackb_cap_multiplier', '20')
  on conflict (key) do update set value = excluded.value;
insert into app_config(key, value) values ('job_open_timeout_hours', '48')
  on conflict (key) do nothing;

alter table marketplace_jobs alter column base_price_cents set default 1000;

-- Bring any still-open (test) jobs up to the new floor so quotes validate cleanly.
update marketplace_jobs set base_price_cents = 1000
 where state in ('open', 'price_proposed') and base_price_cents < 1000;

-- ── create_marketplace_job: base price now sourced from config ───────────────
create or replace function create_marketplace_job(p_resolution_id uuid, p_module text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype; v_id uuid; v_base int;
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

  select coalesce((select value::int from app_config where key='marketplace_base_price_cents'), 1000)
    into v_base;
  insert into marketplace_jobs (resolution_id, module, state, base_price_cents)
    values (p_resolution_id, p_module, 'open', v_base)
    returning id into v_id;
  return v_id;
end $$;
grant execute on function create_marketplace_job(uuid, text) to authenticated;

-- ── accept_job: retired. Quote-first has no one-tap accept. ───────────────────
-- Kept as a hard stop so a stale client or direct RPC call can't start an
-- unpaid job. Specialists must go through propose_job_price.
create or replace function accept_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  raise exception 'one-tap accept is retired — send a quote with propose_job_price instead';
end $$;
grant execute on function accept_job(uuid) to authenticated;

-- ── escalate_resolution: quote-first copy, self-dealing guard kept (16.3) ─────
create or replace function escalate_resolution(p_resolution_id uuid, p_context text, p_module text default null)
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
  end if;

  v_module := nullif(btrim(coalesce(p_module, '')), '');
  if v_module is null and r.solution_id is not null then
    select component_name into v_module from solutions where id = r.solution_id;
  end if;

  v_job := create_marketplace_job(p_resolution_id, v_module);
  insert into notifications (user_id, type, title, body, data)
    select cp.user_id, 'job_available', 'New job' || coalesce(' · ' || v_module, ''),
           'A user needs help with an IFS error — review it and send a quote.',
           jsonb_build_object('job_id', v_job, 'module', v_module)
      from consultant_profiles cp
     where cp.status = 'approved' and cp.user_id <> v_user            -- self-dealing guard
       and (v_module is null or v_module = any (cp.modules));
end $$;
grant execute on function escalate_resolution(uuid, text, text) to authenticated;

-- ── my_open_jobs(): the user's escalations still waiting for a quote ──────────
-- Powers the "a specialist is reviewing…" status and the no-specialist fallback
-- (launch-blocker #1): the client shows a "taking longer than usual" note once
-- a job has sat open past job_open_timeout_hours, so an unquoted escalation
-- never just hangs silently.
create or replace function my_open_jobs()
returns table (job_id uuid, module text, error_code text, error_text text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.module, r.error_code, r.error_text, j.created_at
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where r.user_id = v_user and j.state = 'open'
     order by j.created_at desc;
end $$;
grant execute on function my_open_jobs() to authenticated;
