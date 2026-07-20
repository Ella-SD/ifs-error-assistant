-- ============================================================================
-- Moat instrumentation — cross-company reuse tracking
--
-- The core thesis: one company's fix helps EVERY other company hitting the same
-- IFS error. That's only true if fixes actually get reused across companies —
-- an assumption we don't have data for yet. This migration records which
-- companies accept which shared solutions so the moat dashboard can measure it
-- BEFORE we invest in the marketplace.
--
-- (The full consultant marketplace — roles, jobs, Connect payouts, tiers — is
-- deferred until this validates. Only the reuse signal is built now.)
-- ============================================================================

-- One row per (solution, company) the first time that company accepts a fix.
create table if not exists solution_acceptances (
  id          uuid primary key default gen_random_uuid(),
  solution_id uuid not null references solutions(id) on delete cascade,
  company_id  uuid not null references companies(id) on delete cascade,
  accepted_at timestamptz not null default now(),
  unique (solution_id, company_id)
);
create index if not exists solution_acceptances_solution_idx on solution_acceptances(solution_id);
create index if not exists solution_acceptances_company_idx  on solution_acceptances(company_id);

-- ── Extend feedback to record the accepting company ─────────────────────────
-- Same body as before (0002) plus: on a positive acceptance, record the caller's
-- company (deduped per company). Company users only — personal/PAYG individuals
-- have no company, so they don't count toward cross-COMPANY reuse.
create or replace function record_solution_feedback(p_solution_id uuid, p_accepted boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  s         solutions%rowtype;
  rate      numeric;
  v_company uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  select * into s from solutions where id = p_solution_id for update;
  if not found then raise exception 'solution not found'; end if;
  if s.status not in ('PUBLISHED', 'VERIFIED', 'NEEDS_REVIEW') then
    raise exception 'feedback only allowed on live solutions';
  end if;

  if p_accepted then
    update solutions
       set times_accepted = times_accepted + 1,
           last_verified  = now(),
           status = case when status = 'PUBLISHED' then 'VERIFIED'::solution_status
                         else status end
     where id = p_solution_id;

    -- moat signal: record which company accepted this fix
    select company_id into v_company from users where id = auth.uid();
    if v_company is not null then
      insert into solution_acceptances (solution_id, company_id)
        values (p_solution_id, v_company)
        on conflict (solution_id, company_id) do nothing;
    end if;
  else
    update solutions set times_rejected = times_rejected + 1 where id = p_solution_id;
    select * into s from solutions where id = p_solution_id;
    if s.times_served >= 3 then
      rate := s.times_accepted::numeric / nullif(s.times_served, 0);
      if rate < 0.3 and s.status in ('PUBLISHED', 'VERIFIED') then
        update solutions set status = 'NEEDS_REVIEW' where id = p_solution_id;
      end if;
    end if;
  end if;
end $$;

-- ── Dashboard RPCs (platform_admin only) ────────────────────────────────────
-- Aggregate platform-wide numbers — guarded so a single company can't read the
-- whole platform's reuse data. "Cross-company" = a solution accepted by >= 2
-- distinct companies (the moat working).
create or replace function moat_metrics()
returns json
language plpgsql stable security definer set search_path = public as $$
declare result json;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select json_build_object(
    'live_solutions',            (select count(*) from solutions where status in ('PUBLISHED','VERIFIED','NEEDS_REVIEW')),
    'solutions_accepted',        (select count(distinct solution_id) from solution_acceptances),
    'cross_company_solutions',   (select count(*) from (
                                     select solution_id from solution_acceptances
                                     group by solution_id having count(distinct company_id) >= 2) t),
    'total_acceptances',         (select count(*) from solution_acceptances),
    'distinct_companies',        (select count(distinct company_id) from solution_acceptances)
  ) into result;
  return result;
end $$;

-- Top fixes by number of DISTINCT companies that accepted them (the flywheel's hits).
create or replace function top_reused_solutions(p_limit int default 15)
returns table (solution_id uuid, error_code text, title text, company_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select sa.solution_id, s.error_code, s.title, count(distinct sa.company_id) as company_count
    from solution_acceptances sa
    join solutions s on s.id = sa.solution_id
    group by sa.solution_id, s.error_code, s.title
    order by company_count desc, s.error_code
    limit p_limit;
end $$;

grant execute on function moat_metrics()            to authenticated;
grant execute on function top_reused_solutions(int) to authenticated;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table solution_acceptances enable row level security;
create policy acceptances_select on solution_acceptances for select
  using (company_id = auth_company_id() or is_platform_admin());
