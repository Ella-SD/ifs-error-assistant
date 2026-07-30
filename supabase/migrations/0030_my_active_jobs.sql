-- ============================================================================
-- User-side visibility for a specialist actively working an approved job.
--
-- Gap found in smoke test: after a user approves + pays a quote, the job moves to
-- 'in_progress' (then 'submitted') — but the user had NO card for those states, so
-- a paying customer saw nothing between "approve" and the final delivered fix, and
-- the consultant charge ($ they paid) was invisible on their side.
--
-- my_active_jobs() returns those jobs with paid_cents = the consultant amount the
-- user was charged (proposed − already-paid-toward-this-error), so the client can
-- show "🔧 A specialist is resolving this — you paid $X.XX."
-- ============================================================================

create or replace function my_active_jobs()
returns table (job_id uuid, state text, module text, error_code text, error_text text,
               paid_cents int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.state::text, j.module, r.error_code, r.error_text,
           greatest(0, coalesce(j.proposed_price_cents, 0) - coalesce(r.price_cents, 0)),
           j.created_at
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where r.user_id = v_user and j.state in ('in_progress', 'submitted')
     order by j.created_at desc;
end $$;
grant execute on function my_active_jobs() to authenticated;
