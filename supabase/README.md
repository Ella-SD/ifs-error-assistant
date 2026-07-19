# Supabase backend — Phase 2, Step 1

Schema, access-control policies, and seed data for the IFS Error Assistant's move
from a static localStorage prototype to a real multi-tenant backend.

**Scope of this slice:** accounts, companies, roles, a shared solutions library,
and a company-private archive. **Not** in here (later requests): Stripe/payments,
subscription tiers, consultant portal, bidding, royalties.

## Files & apply order

Apply in this exact order — RLS policies depend on the functions, which depend on
the tables:

| # | File | What it does |
|---|------|--------------|
| 1 | `migrations/0001_schema.sql` | Extensions, enums, tables, constraints, indexes |
| 2 | `migrations/0002_functions.sql` | RLS helper predicates + all RPCs (onboarding, feedback, moderation) |
| 3 | `migrations/0003_rls.sql` | Enables RLS and defines every policy |
| 4 | `migrations/0004_assembled_sources.sql` | Adds `solutions.assembled_sources` for the Tier-2 "assemble a fix" feature |
| 5 | `seed.sql` | The 10 founding solutions (idempotent — skips if `solutions` is non-empty) |

`test/` is a **local-only validation harness** and must NOT be applied to the real
project — it stubs the `auth` schema and roles that Supabase already provides.

## App integration (Steps 3–6) — status

`../index.html` is fully wired to this backend and verified end-to-end locally:
auth gate + onboarding (create company / accept invite), the solutions library and
review queue on the shared `solutions` table (moderation via `moderate_solution`,
feedback via `record_solution_feedback`), the company-private archive on
`archive_entries`, and the IFS version on `companies.ifs_version`. The publishable
key is embedded in `index.html` (public by design; RLS is the boundary).

**Archive fields dropped in the move to Postgres:** the free-text "what were you
trying to do" (`activity`) and the match-confidence label are no longer stored
(the 0001 `archive_entries` schema has no column for them). Everything else —
error text, screen, version hint, catalog match, solution link — is preserved.
Say the word and I'll add two columns to restore them.

## The two architectural calls (deliberate, expensive to reverse)

- **`solutions` is shared platform-wide** — no `company_id` column at all. IFS
  error codes are identical across every customer; pooling fixes is the moat.
- **`archive_entries` is company-private** — `NOT NULL company_id` + RLS, and
  crucially **no `platform_admin` escape hatch** (an admin can moderate shared
  solutions but has no business reading a company's screenshots).

## Access-control model in one paragraph

Direct client access governed by RLS is the security boundary (no Vercel CRUD
tier). The one thing RLS can't express — "any user may bump a shared solution's
feedback counters but nobody may self-publish" (column-level intent on a row they
don't own) — is handled by `SECURITY DEFINER` RPCs instead:
`record_solution_served`, `record_solution_feedback` (open to all authenticated
users, hardcoded to safe transitions) and `moderate_solution` (approve / reject /
unpublish, gated on `is_platform_admin()` at the DB level, not just the UI).

## Bootstrapping the first `platform_admin`

There is **no signup path** to `platform_admin` — self-service escalation would be
a vulnerability. Grant it manually after the owner has signed up normally:

```sql
update users set role = 'platform_admin', company_id = null
where email = 'you@example.com';
```

Run this from the Supabase SQL editor (service role) once, for your own account.

## Onboarding flow

Signup (Supabase Auth) creates only an `auth.users` row. The app then calls one of:

- `create_company_and_join(company_name, ifs_version)` — new company; caller
  becomes `company_admin`.
- `accept_company_invite()` — attaches the caller to whichever company
  pre-authorized their email (a `company_admin` adds it to `company_invites`).

Until one succeeds the user has a session but belongs to no company and can see
nothing — a safe default.

## Local validation

With a local Postgres running (no Supabase project needed):

```
psql -v ON_ERROR_STOP=1 -f supabase/test/run_all.sql
```

Applies the real migrations against a stubbed `auth` schema, runs RLS/RPC
assertions (tenant isolation, review-gate enforcement, feedback tamper-resistance,
the platform_admin/archive asymmetry), then rolls everything back. Reaching the
`ALL RLS / RPC ASSERTIONS PASSED` banner means it passed.
