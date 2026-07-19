-- ============================================================================
-- Phase 2 · Step 1 — Schema
-- IFS Error Assistant: accounts, companies, roles, shared solutions, private archive
--
-- Applied FIRST. Defines extensions, enums, tables, constraints, indexes.
-- Functions live in 0002_functions.sql; RLS policies in 0003_rls.sql.
-- ============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- ── Enums ───────────────────────────────────────────────────────────────────

-- Roles for THIS slice only. 'consultant' is intentionally omitted — it belongs
-- to the later marketplace request and adding an enum value later is trivial.
create type user_role as enum ('company_admin', 'company_member', 'platform_admin');

-- All 7 solution statuses the Phase 1 app actually uses (verified against
-- index.html). Missing any of these would make the seed migration or the
-- existing lifecycle logic fail:
--   NO_INSTRUCTION  catalog entry known, no solution written yet (empty steps)
--   DRAFT           being authored (incl. AI-assembled Tier-2 drafts)
--   PENDING_REVIEW  submitted, awaiting platform_admin approval
--   PUBLISHED       approved, live to end users
--   VERIFIED        published + at least one end user confirmed it helped
--   NEEDS_REVIEW    was live but acceptance rate dropped — flagged BUT STILL LIVE
--   REJECTED        platform_admin rejected
create type solution_status as enum (
  'NO_INSTRUCTION', 'DRAFT', 'PENDING_REVIEW',
  'PUBLISHED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED'
);

-- ── companies ───────────────────────────────────────────────────────────────
-- ifs_version replaces the Phase 1 localStorage "ask once, remember" setting.
create table companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  ifs_version text not null default 'IFS10',
  created_at  timestamptz not null default now()
);

-- ── users ───────────────────────────────────────────────────────────────────
-- 1:1 with auth.users (Supabase Auth owns credentials/sessions). company_id is
-- null ONLY for platform_admin (the platform operator, not tied to a tenant);
-- company_admin/company_member must always belong to a company.
create table users (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  company_id uuid references companies(id) on delete set null,
  role       user_role not null default 'company_member',
  created_at timestamptz not null default now(),
  constraint company_required_for_company_roles
    check (role = 'platform_admin' or company_id is not null)
);
create index users_company_id_idx on users(company_id);

-- ── company_invites ─────────────────────────────────────────────────────────
-- The join mechanism for a second+ user of an existing company. A user may NOT
-- self-declare a company_id (that would let anyone join any company), so a
-- company_admin pre-authorizes an email here; matching signups attach via the
-- accept_company_invite() RPC. Deliberately minimal: no token expiry, no email
-- delivery — that can be a follow-up if it proves necessary.
create table company_invites (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies(id) on delete cascade,
  email       text not null,
  role        user_role not null default 'company_member',
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz,
  -- invites can never grant platform_admin — that is manual-grant only
  constraint invite_role_not_platform check (role <> 'platform_admin'),
  unique (company_id, email)
);
create index company_invites_email_idx on company_invites(lower(email));

-- ── solutions ───────────────────────────────────────────────────────────────
-- SHARED, platform-wide. Deliberately NO company_id column: IFS error codes are
-- Oracle-hardcoded strings identical across every customer, and pooling fixes is
-- the product's moat. This is the call flagged as expensive-to-reverse and
-- re-confirmed before writing.
--
-- Columns beyond the plan's minimal sketch (lu_name, package_name,
-- component_code, component_name, error_template, ifs_version) are carried
-- forward from the Phase 1 record because error_code ALONE is not unique against
-- the 53k-row catalog — these are how a solution re-links to its catalog entry.
create table solutions (
  id                     uuid primary key default gen_random_uuid(),
  error_code             text not null,
  lu_name                text,
  package_name           text,
  component_code         text,
  component_name         text,
  error_template         text,
  ifs_version            text not null default 'IFS10',
  title                  text not null,
  who_acts               text,
  instructions           jsonb not null default '[]'::jsonb,
  status                 solution_status not null default 'DRAFT',
  source                 text not null default 'ADMIN',
  reject_note            text not null default '',
  times_served           int not null default 0,
  times_accepted         int not null default 0,
  times_rejected         int not null default 0,
  contributed_by_user_id uuid references users(id) on delete set null,
  last_verified          timestamptz,
  published_at           timestamptz,
  created_at             timestamptz not null default now()
);
create index solutions_error_code_idx on solutions(error_code);
create index solutions_status_idx     on solutions(status);

-- ── archive_entries ─────────────────────────────────────────────────────────
-- COMPANY-SCOPED, RLS-enforced. Opposite call from solutions: screenshots and
-- extracted text can contain real customer/order/business data and must be
-- walled off per company. Note the asymmetry — platform_admin gets elevated
-- access to solutions but NOT to archive_entries (see 0003_rls.sql).
create table archive_entries (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references companies(id) on delete cascade,
  submitted_by_user_id   uuid references users(id) on delete set null,
  error_text             text,
  screen_name            text,
  ifs_version_hint       text,
  catalog_match_error_code text,     -- references catalog by code (catalog stays client-side JSON), not an FK
  solution_id            uuid references solutions(id) on delete set null,
  created_at             timestamptz not null default now()
);
create index archive_entries_company_id_idx on archive_entries(company_id);
