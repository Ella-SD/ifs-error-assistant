-- ============================================================================
-- "My fixes" — durable re-access to resolutions a user already unlocked (paid or
-- subscriber), so a lost page / re-search never means paying twice for the same
-- resolved instance (scope 8.6). Per 8.1, this serves the IMMUTABLE snapshot the
-- user originally saw — not the current (possibly revised) solution.
--
-- This is the ONLY sanctioned read of resolutions.steps_snapshot after the 0014
-- lock: SECURITY DEFINER, scoped strictly to the caller's OWN resolutions
-- (user_id = auth.uid(), NOT company-wide — "my fixes" is personal). Reuses the
-- same gated-access pattern as reveal_solution rather than exposing the column.
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
       and r.steps_snapshot is not null   -- only ones actually unlocked/revealed
     order by r.created_at desc;
end $$;

grant execute on function my_resolutions() to authenticated;
