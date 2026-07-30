-- ============================================================================
-- Marketplace redesign · Stage 4b — consultant sees their own fix + the note.
-- (Run after 0036.)
--
-- my_consultant_jobs now also returns the consultant's own submitted steps
-- (so they can review / prefill a revision) and user_note (the reason the user
-- rejected, shown on a 'revision_requested' job). Return type changed → drop.
-- ============================================================================

drop function if exists my_consultant_jobs() cascade;
create function my_consultant_jobs()
returns table (job_id uuid, state job_state, module text, base_price_cents int,
               proposed_price_cents int, created_at timestamptz, deadline_at timestamptz,
               error_code text, error_text text, screen_name text, activity text,
               user_note text, solution_title text, solution_who text, solution_steps jsonb)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.state, j.module, j.base_price_cents, j.proposed_price_cents,
           j.created_at, j.deadline_at, r.error_code, r.error_text, r.screen_name, r.activity,
           j.user_note, s.title, s.who_acts, s.instructions
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join solutions s on s.id = j.solution_id
     where j.consultant_id = v_user
     order by j.updated_at desc;
end $$;
grant execute on function my_consultant_jobs() to authenticated;

notify pgrst, 'reload schema';
