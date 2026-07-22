-- ============================================================================
-- Route marketplace jobs by the catalog's canonical module, not the solution's
-- (possibly drifting) component_name. The catalog is the source of truth for
-- which IFS component an error belongs to; a solution just fixes that error. The
-- catalog lives client-side, so the client derives the module by error code and
-- passes it here. Fallback to the solution's component_name only for errors not
-- in the catalog (uncataloged AI-assemble / consultant fixes).
-- ============================================================================

drop function if exists escalate_resolution(uuid, text);

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

  -- Prefer the catalog-derived module the client passed; fall back to the solution.
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
     where cp.status = 'approved' and (v_module is null or v_module = any (cp.modules));
end $$;

grant execute on function escalate_resolution(uuid, text, text) to authenticated;
