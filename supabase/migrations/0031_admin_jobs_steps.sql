-- ============================================================================
-- Let the admin review the consultant's submitted steps in the Marketplace tab.
--
-- Before: admin_jobs returned only the fix TITLE, so to review the actual steps
-- an admin had to hunt in the Solution Library — where an AI-assembled solution
-- and the consultant's solution for the same error look alike. That caused a
-- real "am I looking at the right fix?" confusion.
--
-- Now admin_jobs also returns the submitted solution's who_acts, steps, and
-- source, so the client can show the exact consultant steps inline next to the
-- Deliver / Refund buttons. Return type changed → drop first.
-- ============================================================================

drop function if exists admin_jobs();
create or replace function admin_jobs()
returns table (job_id uuid, state job_state, module text, created_at timestamptz,
               consultant_email text, solution_id uuid, solution_title text,
               solution_who text, solution_steps jsonb, solution_source text,
               error_code text, error_text text, user_email text,
               proposed_price_cents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select j.id, j.state, j.module, j.created_at,
           cu.email, j.solution_id, s.title, s.who_acts, s.instructions, s.source,
           r.error_code, r.error_text, ru.email, j.proposed_price_cents
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join users ru on ru.id = r.user_id
      left join users cu on cu.id = j.consultant_id
      left join solutions s on s.id = j.solution_id
     order by (j.state = 'submitted') desc, j.updated_at desc;
end $$;
grant execute on function admin_jobs() to authenticated;
