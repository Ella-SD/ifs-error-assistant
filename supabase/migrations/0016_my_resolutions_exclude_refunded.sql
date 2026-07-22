-- ============================================================================
-- Exclude refunded resolutions from "My fixes".
--
-- A refunded resolution means the user got their money back — so ongoing durable
-- access should end too, otherwise "pay → view/download → request refund → keep
-- free access" is a loophole. Enforced server-side in the RPC (not just hidden in
-- the UI). All other unlocked states (matched_unlocked, resolved_confirmed,
-- escalated, resolved_by_consultant) remain accessible.
-- ============================================================================

create or replace function my_resolutions()
returns table (
  id             uuid,
  created_at     timestamptz,
  state          resolution_state,
  outcome        text,
  error_code     text,
  error_text     text,
  screen_name    text,
  price_cents    int,
  solution_title text,
  who_acts       text,
  steps          jsonb
)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select r.id, r.created_at, r.state, r.outcome,
           r.error_code, r.error_text, r.screen_name, r.price_cents,
           s.title, s.who_acts, r.steps_snapshot
      from resolutions r
      left join solutions s on s.id = r.solution_id
     where r.user_id = v_user
       and r.steps_snapshot is not null
       and r.state <> 'refunded'        -- refunded → access ends
     order by r.created_at desc;
end $$;

grant execute on function my_resolutions() to authenticated;
