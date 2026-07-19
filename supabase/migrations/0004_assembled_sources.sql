-- ============================================================================
-- Phase 2 · Step 4 — add assembled_sources to solutions
-- The Tier-2 "assemble a fix" feature has Claude cite the IFS-docs / community /
-- web URLs it used; the UI shows them under an AI-assembled draft. Step 1's
-- schema didn't carry this column, so add it. Additive + idempotent.
-- ============================================================================

alter table solutions
  add column if not exists assembled_sources jsonb not null default '[]'::jsonb;
