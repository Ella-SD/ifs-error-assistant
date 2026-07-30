-- ============================================================================
-- Marketplace redesign · Stage 1a — new job states (run FIRST, on its own).
--
-- Postgres won't let a newly added enum value be USED in the same transaction it
-- was added, so the ADD VALUEs live in their own migration ahead of 0033 (which
-- references them in functions + a data backfill).
--
-- The new model: a consultant DELIVERS directly to the user (no admin pre-gate);
-- the user validates it. States added for that loop:
--   confirmed          — user 👍 (or 7-day auto-confirm) → credit becomes available
--   revision_requested — user 👎 → consultant revises & resubmits
--   disputed           — unresolved → admin arbitrates
-- ============================================================================

alter type job_state add value if not exists 'confirmed';
alter type job_state add value if not exists 'revision_requested';
alter type job_state add value if not exists 'disputed';
