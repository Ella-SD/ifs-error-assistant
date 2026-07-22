-- ============================================================================
-- Marketplace v1 · Phase 1 — read RPCs that power the consultant + admin UIs.
--
-- Consultants must see a job's error context to work it, but the resolutions RLS
-- deliberately doesn't grant them row access. These SECURITY DEFINER views return
-- exactly what's needed (error text + the user's context, NEVER the screenshot —
-- 9.4), scoped to eligible jobs only.
-- ============================================================================

-- Open jobs a consultant is eligible for (approved + module match).
create or replace function open_jobs_for_consultant()
returns table (job_id uuid, module text, base_price_cents int, created_at timestamptz,
               error_code text, error_text text, screen_name text, activity text)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if not is_approved_consultant(v_user) then raise exception 'not an approved consultant'; end if;
  return query
    select j.id, j.module, j.base_price_cents, j.created_at,
           r.error_code, r.error_text, r.screen_name, r.activity
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where j.state = 'open'
       and exists (select 1 from consultant_profiles cp
                   where cp.user_id = v_user and cp.status = 'approved'
                     and (j.module is null or j.module = any (cp.modules)))
     order by j.created_at;
end $$;

-- The caller's own claimed jobs (any state), with context.
create or replace function my_consultant_jobs()
returns table (job_id uuid, state job_state, module text, base_price_cents int,
               proposed_price_cents int, created_at timestamptz, deadline_at timestamptz,
               error_code text, error_text text, screen_name text, activity text)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.state, j.module, j.base_price_cents, j.proposed_price_cents,
           j.created_at, j.deadline_at, r.error_code, r.error_text, r.screen_name, r.activity
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where j.consultant_id = v_user
     order by j.updated_at desc;
end $$;

-- Admin oversight: all jobs (submitted first, for delivery), with the parties.
create or replace function admin_jobs()
returns table (job_id uuid, state job_state, module text, created_at timestamptz,
               consultant_email text, solution_id uuid, solution_title text,
               error_code text, error_text text, user_email text,
               proposed_price_cents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select j.id, j.state, j.module, j.created_at,
           cu.email, j.solution_id, s.title, r.error_code, r.error_text, ru.email, j.proposed_price_cents
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join users ru on ru.id = r.user_id
      left join users cu on cu.id = j.consultant_id
      left join solutions s on s.id = j.solution_id
     order by (j.state = 'submitted') desc, j.updated_at desc;
end $$;

-- Admin: consultant applications (pending first).
create or replace function admin_consultant_applications()
returns table (user_id uuid, email text, modules text[], tier text, status text, credit_balance_cents int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select cp.user_id, u.email, cp.modules, cp.tier, cp.status, cp.credit_balance_cents
      from consultant_profiles cp
      join users u on u.id = cp.user_id
     order by (cp.status = 'pending') desc, cp.updated_at desc;
end $$;

grant execute on function open_jobs_for_consultant()      to authenticated;
grant execute on function my_consultant_jobs()            to authenticated;
grant execute on function admin_jobs()                    to authenticated;
grant execute on function admin_consultant_applications() to authenticated;
