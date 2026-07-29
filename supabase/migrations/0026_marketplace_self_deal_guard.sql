-- ============================================================================
-- Marketplace self-dealing guard (scope 16.3).
--
-- One account can be BOTH a user and a consultant. Without a guard, a consultant
-- could see and claim the very job that originated from their OWN submitted
-- error, then "resolve" it and collect credit for no real work. This closes that
-- loophole in every path: the open-jobs queue, both claim paths (accept_job /
-- propose_job_price), and the new-job notification fan-out. submit_job_fix is
-- covered transitively (a consultant can't submit for a job they couldn't claim).
--
-- The originating user of a job = the resolution's user_id.
-- Recreates the current bodies verbatim, adding only the guard lines.
-- ============================================================================

-- 1) Queue: hide the consultant's own originated jobs.
create or replace function open_jobs_for_consultant()
returns table (job_id uuid, module text, base_price_cents int, created_at timestamptz,
               error_code text, error_text text, screen_name text, activity text)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if not is_approved_consultant(v_user) then raise exception 'not an approved consultant'; end if;
  return query
    select j.id, j.module, j.base_price_cents, j.created_at,
           r.error_code, r.error_text, r.screen_name, r.activity
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where j.state = 'open'
       and r.user_id <> v_user                            -- self-dealing guard
       and exists (select 1 from consultant_profiles cp
                   where cp.user_id = v_user and cp.status = 'approved'
                     and (j.module is null or j.module = any (cp.modules)))
     order by j.created_at;
end $$;

-- 2) Track A claim: reject the consultant's own job.
create or replace function accept_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_days int; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner = v_user then raise exception 'you cannot claim your own job'; end if;   -- self-dealing guard
  if not _consultant_can_take(v_user, j.module) then raise exception 'not eligible for this job'; end if;
  if j.state <> 'open' then raise exception 'job is no longer open'; end if;
  select coalesce((select value::int from app_config where key='marketplace_sla_days'), 7) into v_days;
  update marketplace_jobs
     set consultant_id=v_user, state='in_progress', claimed_at=now(),
         deadline_at = now() + make_interval(days => v_days), updated_at=now()
   where id = p_job_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'in_progress','A specialist is on it',
            'A specialist picked up your issue and is working on a fix.',
            jsonb_build_object('job_id', p_job_id));
end $$;

-- 3) Track B propose: reject the consultant's own job.
create or replace function propose_job_price(p_job_id uuid, p_price_cents int)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_days int; v_cap_mult int; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner = v_user then raise exception 'you cannot claim your own job'; end if;   -- self-dealing guard
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
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'price_proposed','A price came back for your issue',
            'A specialist can take this for $' || to_char(p_price_cents/100.0,'FM999990.00') || '. Approve to proceed.',
            jsonb_build_object('job_id', p_job_id, 'price_cents', p_price_cents));
end $$;

-- 4) Escalation fan-out: don't even notify the originator about their own job.
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
           'A user needs help with an IFS error — one-tap accept at $4.99.',
           jsonb_build_object('job_id', v_job, 'module', v_module)
      from consultant_profiles cp
     where cp.status = 'approved' and cp.user_id <> v_user            -- self-dealing guard
       and (v_module is null or v_module = any (cp.modules));
end $$;

grant execute on function escalate_resolution(uuid, text, text) to authenticated;
