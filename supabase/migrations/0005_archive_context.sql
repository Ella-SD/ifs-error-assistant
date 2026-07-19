-- ============================================================================
-- Phase 2 · Step 6 follow-up — restore archive context columns
-- Deliberate support/audit fields that the 0001 archive_entries schema omitted:
--   activity          the user's free-text "what were you trying to do?"
--   match_confidence  the catalog-match confidence label (high/medium/low)
-- Additive + idempotent.
-- ============================================================================

alter table archive_entries
  add column if not exists activity         text,
  add column if not exists match_confidence text;
