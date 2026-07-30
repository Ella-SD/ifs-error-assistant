-- ============================================================================
-- Marketplace redesign · Stage 2 — consultant delivers direct + user validates.
-- (Run after 0032/0033.)
--
--   deliver_fix   — consultant delivers their fix straight to the user (no admin
--                   gate). Credit is computed now but stays PENDING (derived)
--                   until confirm/window. Also used to RE-deliver after a 👎.
--   confirm_fix   — user 👍 → job 'confirmed' → credit becomes available.
--   reject_fix    — user 👎 → job 'revision_requested' → consultant revises.
--   my_jobs_awaiting_validation — the user's delivered fixes needing 👍/👎.
-- ============================================================================

-- Reason the user gave when rejecting / disputing (shown to the consultant).
alter table marketplace_jobs add column if not exists user_note text;

-- ── Consultant delivers (or re-delivers after a revision) ────────────────────
create or replace function deliver_fix(p_job_id uuid, p_title text, p_who text, p_steps jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; r resolutions%rowtype;
        v_sol uuid; v_tier text; v_split int; v_fee int; v_credit int;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.consultant_id <> v_user then raise exception 'not your job'; end if;
  if j.state not in ('in_progress', 'revision_requested') then
    raise exception 'job is not deliverable in its current state';
  end if;
  if p_steps is null or jsonb_array_length(p_steps) = 0 then raise exception 'no steps to deliver'; end if;
  select * into r from resolutions where id = j.resolution_id;

  -- Reuse the solution when re-delivering (a revision), else create it.
  if j.solution_id is not null then
    update solutions set title = coalesce(p_title, title), who_acts = p_who,
           instructions = p_steps
     where id = j.solution_id returning id into v_sol;
  else
    insert into solutions (error_code, component_name, title, who_acts, source, status,
                           instructions, contributed_by_user_id)
      values (r.error_code, j.module, coalesce(p_title, 'Consultant fix for ' || coalesce(r.error_code,'error')),
              p_who, 'CONSULTANT', 'PENDING_REVIEW', p_steps, v_user)
      returning id into v_sol;
  end if;

  v_fee := coalesce(j.proposed_price_cents, j.base_price_cents);
  select tier into v_tier from consultant_profiles where user_id = v_user;
  select coalesce((select value::int from app_config where key = 'tier_split_' || coalesce(v_tier,'bronze')), 70) into v_split;
  v_credit := (v_fee * v_split) / 100;

  -- Deliver straight to the user; the fix shows in "My fixes" for validation.
  update resolutions set verified_steps = p_steps, state = 'resolved_by_consultant', updated_at = now()
   where id = j.resolution_id;
  update marketplace_jobs set solution_id = v_sol, state = 'delivered', delivered_at = now(),
         credit_cents = v_credit, user_note = null, updated_at = now()
   where id = p_job_id;

  insert into notifications (user_id, type, title, body, data)
    values (r.user_id, 'delivered', 'Your fix is ready',
            'A specialist delivered a fix — open "My fixes" and let us know if it worked.',
            jsonb_build_object('job_id', p_job_id));
end $$;
grant execute on function deliver_fix(uuid, text, text, jsonb) to authenticated;

-- ── User confirms the fix worked (👍) → credit becomes available ──────────────
create or replace function confirm_fix(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner <> v_user then raise exception 'not your job'; end if;
  if j.state <> 'delivered' then raise exception 'nothing to confirm'; end if;

  update marketplace_jobs set state = 'confirmed', confirmed_at = now(), updated_at = now() where id = p_job_id;
  update resolutions set state = 'resolved_confirmed', outcome = 'up', updated_at = now() where id = j.resolution_id;
  if j.solution_id is not null then
    update solutions set times_accepted = coalesce(times_accepted,0) + 1 where id = j.solution_id;
  end if;
  insert into notifications (user_id, type, title, body, data)
    values (j.consultant_id, 'fix_confirmed', 'Fix confirmed — credit available',
            'The user confirmed your fix. Your credit is now available to cash out.',
            jsonb_build_object('job_id', p_job_id));
end $$;
grant execute on function confirm_fix(uuid) to authenticated;

-- ── User says it didn't work (👎) → back to the consultant to revise ─────────
create or replace function reject_fix(p_job_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner <> v_user then raise exception 'not your job'; end if;
  if j.state <> 'delivered' then raise exception 'nothing to reject'; end if;

  update marketplace_jobs set state = 'revision_requested',
         user_note = nullif(btrim(coalesce(p_reason,'')),''), updated_at = now()
   where id = p_job_id;
  update resolutions set state = 'resolved_disputed', outcome = 'down', updated_at = now() where id = j.resolution_id;
  insert into notifications (user_id, type, title, body, data)
    values (j.consultant_id, 'revision_requested', 'A fix needs revision',
            'The user said the fix didn''t work' ||
              coalesce(': "' || nullif(btrim(coalesce(p_reason,'')),'') || '"', '') ||
              '. Please revise and re-deliver.',
            jsonb_build_object('job_id', p_job_id));
end $$;
grant execute on function reject_fix(uuid, text) to authenticated;

-- ── The user's delivered fixes awaiting their 👍/👎 ──────────────────────────
create or replace function my_jobs_awaiting_validation()
returns table (job_id uuid, module text, error_code text, error_text text,
               solution_title text, who_acts text, steps jsonb, delivered_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.module, r.error_code, r.error_text, s.title, s.who_acts, s.instructions, j.delivered_at
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join solutions s on s.id = j.solution_id
     where r.user_id = v_user and j.state = 'delivered'
     order by j.delivered_at desc;
end $$;
grant execute on function my_jobs_awaiting_validation() to authenticated;

notify pgrst, 'reload schema';
