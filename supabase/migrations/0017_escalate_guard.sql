-- ============================================================================
-- Guard escalate_resolution — only a resolution that was actually revealed can be
-- escalated. Previously a crafted call could escalate a never-viewed resolution
-- (matched_locked / no_match / searching). Low-risk (no refund is owed on a $0
-- unrevealed row), but it kept junk out of the admin queue is worth enforcing.
-- Also prevents re-escalating an already-escalated row (which would double-count
-- times_rejected).
-- ============================================================================

create or replace function escalate_resolution(p_resolution_id uuid, p_context text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions where id = p_resolution_id and user_id = v_user for update;
  if not found then raise exception 'resolution not found'; end if;
  if r.state not in ('matched_unlocked', 'resolved_confirmed') then
    raise exception 'only a revealed resolution can be escalated';
  end if;

  update resolutions
     set outcome    = 'down',
         state      = 'escalated',
         activity   = nullif(btrim(coalesce(p_context, '')), ''),
         updated_at = now()
   where id = p_resolution_id;

  if r.solution_id is not null then
    update solutions set times_rejected = times_rejected + 1 where id = r.solution_id;
  end if;
end $$;

grant execute on function escalate_resolution(uuid, text) to authenticated;
