-- ============================================================================
-- Phase 2 · Step 1 — Row Level Security
--
-- Applied THIRD (after 0002_functions — every policy below calls the helper
-- predicates defined there).
--
-- Default posture: RLS ON for every table, deny-by-default, then add only the
-- narrow policies each role legitimately needs. Direct client access is the norm
-- (per the agreed "skip Vercel CRUD, use RLS as the boundary" decision); the
-- tamper-sensitive shared-solution writes go through the RPCs instead.
-- ============================================================================

alter table companies       enable row level security;
alter table users           enable row level security;
alter table company_invites enable row level security;
alter table solutions       enable row level security;
alter table archive_entries enable row level security;

-- ── companies ───────────────────────────────────────────────────────────────
-- See only your own company; platform_admin sees all. No client INSERT (creation
-- is via create_company_and_join RPC). Only that company's admin may edit it
-- (e.g. change ifs_version / name).
create policy companies_select on companies for select
  using (id = auth_company_id() or is_platform_admin());

create policy companies_update on companies for update
  using ((id = auth_company_id() and is_company_admin()) or is_platform_admin())
  with check ((id = auth_company_id() and is_company_admin()) or is_platform_admin());

-- ── users ───────────────────────────────────────────────────────────────────
-- See yourself, co-workers in your company, or everyone if platform_admin.
-- Rows are created only by the onboarding RPCs (definer), so no client INSERT
-- policy. A company_admin may update members within their own company but can
-- never mint a platform_admin (guarded in WITH CHECK).
create policy users_select on users for select
  using (id = auth.uid() or company_id = auth_company_id() or is_platform_admin());

create policy users_update on users for update
  using (
    is_platform_admin()
    or (is_company_admin() and company_id = auth_company_id())
  )
  with check (
    is_platform_admin()
    or (is_company_admin() and company_id = auth_company_id() and role <> 'platform_admin')
  );

-- ── company_invites ─────────────────────────────────────────────────────────
-- Fully owned by the company's admin (and platform_admin). Members never see the
-- invite list.
create policy invites_select on company_invites for select
  using ((company_id = auth_company_id() and is_company_admin()) or is_platform_admin());

create policy invites_insert on company_invites for insert
  with check (
    is_platform_admin()
    or (company_id = auth_company_id() and is_company_admin() and role <> 'platform_admin')
  );

create policy invites_delete on company_invites for delete
  using ((company_id = auth_company_id() and is_company_admin()) or is_platform_admin());

-- ── solutions (SHARED) ──────────────────────────────────────────────────────
-- SELECT: everyone sees live rows (PUBLISHED/VERIFIED/NEEDS_REVIEW — the app's
-- isLive set); platform_admin sees all statuses (needs the review queue);
-- contributors can track their own not-yet-live submissions.
create policy solutions_select on solutions for select
  using (
    status in ('PUBLISHED', 'VERIFIED', 'NEEDS_REVIEW')
    or is_platform_admin()
    or contributed_by_user_id = auth.uid()
  );

-- INSERT: any authenticated user may contribute (manual add / Tier-2 AI draft),
-- but a non-admin can only introduce NON-LIVE rows and must stamp themselves as
-- author — they cannot self-publish. platform_admin may insert anything.
create policy solutions_insert on solutions for insert
  with check (
    is_platform_admin()
    or (
      contributed_by_user_id = auth.uid()
      and status in ('DRAFT', 'PENDING_REVIEW', 'NO_INSTRUCTION')
    )
  );

-- UPDATE (direct):
--   * platform_admin: unrestricted (moderation also has a dedicated RPC).
--   * contributor: may edit ONLY their own non-live row, and the result is
--     capped at non-live (can submit their draft for review, cannot self-publish).
-- Feedback/serve updates on LIVE rows do NOT go through here — they use the
-- SECURITY DEFINER RPCs, because those rows are not owned by the caller.
create policy solutions_update_admin on solutions for update
  using (is_platform_admin())
  with check (is_platform_admin());

create policy solutions_update_own_draft on solutions for update
  using (
    contributed_by_user_id = auth.uid()
    and status in ('DRAFT', 'REJECTED', 'NO_INSTRUCTION')
  )
  with check (
    contributed_by_user_id = auth.uid()
    and status in ('DRAFT', 'PENDING_REVIEW', 'NO_INSTRUCTION')
  );

-- DELETE: platform_admin, or a contributor pruning their own draft/rejected row.
create policy solutions_delete on solutions for delete
  using (
    is_platform_admin()
    or (contributed_by_user_id = auth.uid() and status in ('DRAFT', 'REJECTED'))
  );

-- ── archive_entries (COMPANY-SCOPED) ────────────────────────────────────────
-- Strictly walled per company. NOTE the deliberate asymmetry vs. solutions:
-- there is NO is_platform_admin() escape hatch here — a platform admin has no
-- legitimate reason to read another company's screenshots/extracted text.
create policy archive_select on archive_entries for select
  using (company_id = auth_company_id());

create policy archive_insert on archive_entries for insert
  with check (company_id = auth_company_id() and submitted_by_user_id = auth.uid());

create policy archive_update on archive_entries for update
  using (company_id = auth_company_id())
  with check (company_id = auth_company_id());

create policy archive_delete on archive_entries for delete
  using (company_id = auth_company_id());
