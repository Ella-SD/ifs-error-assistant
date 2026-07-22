-- ============================================================================
-- Escalation states for the MANUAL rejected-fix process (canonical scope Part 13).
--
-- When a solution is thumbs-downed, the user is promised a consultant review →
-- verified fix or full refund. Per Part 13.3 this is delivered by hand (no
-- consultant role, no claim engine, no scheduler, no Connect) — the resolution
-- record just gains a few states, and an admin works the queue + issues refunds
-- through Stripe's own tooling.
--
-- This migration ONLY adds the enum values (the uncontroversial, Part-13-specified
-- part). It is intentionally split from the RPCs/flow:
--   1. Postgres won't let a new enum value be USED in the same transaction it's
--      added, so the escalate / admin RPCs must come in a LATER migration.
--   2. The admin-facing escalation queue crosses the "no platform_admin escape
--      hatch on resolution error-data" posture (an admin would read escalated
--      users' error text to route them). That's a deliberate privacy call that
--      needs Ella's sign-off before it's built — see the plan handed over with
--      this migration. Adding the states now is safe and commits us to nothing.
--
-- resolution_state flow with these added:
--   … → resolved_disputed → escalated → resolved_by_consultant | refunded
-- ============================================================================

alter type resolution_state add value if not exists 'escalated';
alter type resolution_state add value if not exists 'resolved_by_consultant';
alter type resolution_state add value if not exists 'refunded';
