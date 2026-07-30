-- ============================================================================
-- Marketplace redesign · Stage 4 — admin promotes confirmed fixes to "standard".
-- (Run after 0035.)
--
--   admin_promote_to_library — turns a user-confirmed consultant fix into a
--       PUBLISHED library solution so future users can find it by search. This
--       is now the admin's SINGLE quality-review point (review the reusable
--       artifact, not every one-off).
--   admin_jobs (updated) — surfaces user_note + solution_status and orders the
--       queue by what needs attention: disputes first, then deliveries.
-- ============================================================================

create or replace function admin_promote_to_library(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id;
  if not found then raise exception 'job not found'; end if;
  if j.solution_id is null then raise exception 'no fix on this job'; end if;
  if j.state <> 'confirmed' then raise exception 'only a user-confirmed fix can be promoted'; end if;
  update solutions set status = 'PUBLISHED' where id = j.solution_id;
end $$;
grant execute on function admin_promote_to_library(uuid) to authenticated;

-- ── admin_jobs: add user_note + solution_status; attention-ordered ────────────
drop function if exists admin_jobs() cascade;
create function admin_jobs()
returns table (job_id uuid, state job_state, module text, created_at timestamptz,
               consultant_email text, solution_id uuid, solution_title text,
               solution_who text, solution_steps jsonb, solution_source text,
               solution_status text, user_note text,
               error_code text, error_text text, user_email text,
               proposed_price_cents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select j.id, j.state, j.module, j.created_at,
           cu.email, j.solution_id, s.title, s.who_acts, s.instructions, s.source, s.status,
           j.user_note, r.error_code, r.error_text, ru.email, j.proposed_price_cents
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join users ru on ru.id = r.user_id
      left join users cu on cu.id = j.consultant_id
      left join solutions s on s.id = j.solution_id
     order by
       case j.state when 'disputed' then 0 when 'delivered' then 1 when 'confirmed' then 2 else 3 end,
       j.updated_at desc;
end $$;
grant execute on function admin_jobs() to authenticated;

notify pgrst, 'reload schema';
