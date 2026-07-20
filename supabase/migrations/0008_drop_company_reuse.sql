-- ============================================================================
-- Drop the company-based reuse tracking (0007) — per product direction, usage is
-- counted per SOLUTION (solutions.times_accepted), never by company. Reverts
-- record_solution_feedback to not write per-company rows, and removes the
-- now-unused table + admin RPCs.
-- ============================================================================

-- Feedback RPC without the per-company acceptance write (back to the 0002 shape).
create or replace function record_solution_feedback(p_solution_id uuid, p_accepted boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare s solutions%rowtype; rate numeric;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into s from solutions where id = p_solution_id for update;
  if not found then raise exception 'solution not found'; end if;
  if s.status not in ('PUBLISHED','VERIFIED','NEEDS_REVIEW') then
    raise exception 'feedback only allowed on live solutions';
  end if;
  if p_accepted then
    update solutions set times_accepted = times_accepted + 1, last_verified = now(),
      status = case when status = 'PUBLISHED' then 'VERIFIED'::solution_status else status end
      where id = p_solution_id;
  else
    update solutions set times_rejected = times_rejected + 1 where id = p_solution_id;
    select * into s from solutions where id = p_solution_id;
    if s.times_served >= 3 then
      rate := s.times_accepted::numeric / nullif(s.times_served, 0);
      if rate < 0.3 and s.status in ('PUBLISHED','VERIFIED') then
        update solutions set status = 'NEEDS_REVIEW' where id = p_solution_id;
      end if;
    end if;
  end if;
end $$;

drop function if exists moat_metrics();
drop function if exists top_reused_solutions(int);
drop table if exists solution_acceptances;
