-- ============================================================================
-- Phase 2 · Step 1 — Functions (helpers + RPCs)
--
-- Applied SECOND (after 0001_schema, before 0003_rls — the RLS policies call the
-- helper functions defined here).
--
-- SECURITY MODEL NOTE — why RPCs exist at all:
-- Postgres RLS is row-level, not column-level. On the SHARED solutions table any
-- authenticated user (any company) must be able to bump feedback counters and
-- trigger the PUBLISHED->VERIFIED / ->NEEDS_REVIEW auto-transitions, but must NOT
-- be able to set status='PUBLISHED' directly (that would bypass the review gate
-- that is item 5 of this slice). A plain UPDATE policy cannot express "you may
-- touch these columns but not that one." So the tamper-sensitive shared-write
-- paths are encapsulated in SECURITY DEFINER functions that do ONLY their
-- hardcoded logic. All definer functions pin search_path to prevent hijacking.
-- ============================================================================

-- ── RLS helper predicates ───────────────────────────────────────────────────
-- SECURITY DEFINER so they bypass RLS on `users` and therefore do NOT recurse
-- into the users-table policies that call them.

create or replace function auth_company_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from users where id = auth.uid()
$$;

create or replace function is_platform_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from users where id = auth.uid() and role = 'platform_admin')
$$;

create or replace function is_company_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from users where id = auth.uid() and role = 'company_admin')
$$;

-- ── Onboarding RPCs ─────────────────────────────────────────────────────────
-- Called AFTER auth signup completes (the user has a session but no users row
-- yet). Keeping this out of an auth.users trigger means signup itself can never
-- fail/half-commit. Until one of these succeeds, auth_company_id() returns null
-- and the user can see nothing — a safe default.

-- New-company signup: creates the company and attaches the caller as company_admin.
create or replace function create_company_and_join(
  p_company_name text,
  p_ifs_version  text default 'IFS10'
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company_id uuid;
  v_email      text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from users where id = auth.uid()) then
    raise exception 'user already belongs to a company';
  end if;
  if coalesce(trim(p_company_name), '') = '' then
    raise exception 'company name required';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  insert into companies (name, ifs_version)
    values (trim(p_company_name), coalesce(nullif(trim(p_ifs_version), ''), 'IFS10'))
    returning id into v_company_id;

  insert into users (id, email, company_id, role)
    values (auth.uid(), v_email, v_company_id, 'company_admin');

  return v_company_id;
end $$;

-- Invite acceptance: attaches the caller to the company that pre-authorized
-- their email, with the invited role.
create or replace function accept_company_invite()
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_email  text;
  v_invite company_invites%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from users where id = auth.uid()) then
    raise exception 'user already belongs to a company';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  select * into v_invite
    from company_invites
    where lower(email) = lower(v_email) and accepted_at is null
    order by created_at desc
    limit 1;
  if not found then raise exception 'no pending invite for this email'; end if;

  insert into users (id, email, company_id, role)
    values (auth.uid(), v_email, v_invite.company_id, v_invite.role);

  update company_invites set accepted_at = now() where id = v_invite.id;

  return v_invite.company_id;
end $$;

-- ── Shared-solution write RPCs (tamper-resistant) ───────────────────────────

-- Bumped when a live solution is shown as a match. Only touches live rows.
create or replace function record_solution_served(p_solution_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update solutions
     set times_served = times_served + 1
   where id = p_solution_id
     and status in ('PUBLISHED', 'VERIFIED', 'NEEDS_REVIEW');
end $$;

-- End-user feedback. Mirrors recordFeedback() in index.html exactly:
--   accept  -> times_accepted++, last_verified=now(), PUBLISHED->VERIFIED
--   reject  -> times_rejected++, and if served>=3 and accept-rate<0.3 and
--              currently live -> NEEDS_REVIEW (flagged but still live)
-- Crucially, a caller cannot set an arbitrary status through this path.
create or replace function record_solution_feedback(
  p_solution_id uuid,
  p_accepted    boolean
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  s    solutions%rowtype;
  rate numeric;
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

-- ── Moderation RPC (platform_admin only) — item 5 ───────────────────────────
-- The review gate. Enforced here at the DB level, not just hidden in the UI, so
-- it cannot be bypassed by calling the API directly.
create or replace function moderate_solution(
  p_solution_id uuid,
  p_action      text,             -- 'approve' | 'reject' | 'unpublish'
  p_reject_note text default null
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then
    raise exception 'platform_admin role required';
  end if;

  if p_action = 'approve' then
    update solutions
       set status = 'PUBLISHED', published_at = now(), reject_note = ''
     where id = p_solution_id;
  elsif p_action = 'reject' then
    update solutions
       set status = 'REJECTED', reject_note = coalesce(p_reject_note, '')
     where id = p_solution_id;
  elsif p_action = 'unpublish' then
    update solutions set status = 'DRAFT' where id = p_solution_id;
  else
    raise exception 'unknown moderation action: %', p_action;
  end if;
end $$;

-- ── Grants ──────────────────────────────────────────────────────────────────
-- Lock the mutating RPCs down to authenticated users only (revoke the implicit
-- PUBLIC/anon execute first). Helper predicates must be callable by the roles
-- that evaluate the policies.
revoke execute on function create_company_and_join(text, text) from public;
revoke execute on function accept_company_invite()             from public;
revoke execute on function record_solution_served(uuid)        from public;
revoke execute on function record_solution_feedback(uuid, boolean) from public;
revoke execute on function moderate_solution(uuid, text, text) from public;

grant execute on function auth_company_id()      to authenticated;
grant execute on function is_platform_admin()    to authenticated;
grant execute on function is_company_admin()     to authenticated;
grant execute on function create_company_and_join(text, text)      to authenticated;
grant execute on function accept_company_invite()                  to authenticated;
grant execute on function record_solution_served(uuid)             to authenticated;
grant execute on function record_solution_feedback(uuid, boolean)  to authenticated;
grant execute on function moderate_solution(uuid, text, text)      to authenticated;
