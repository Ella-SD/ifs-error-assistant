-- ============================================================================
-- Lock resolutions.steps_snapshot — close the defense-in-depth gap left by 0010.
--
-- 0010 revoked SELECT on solutions.instructions so end users can't read fix steps
-- directly. But every unlock copies those steps into resolutions.steps_snapshot
-- (the immutable liability record), and that column was still readable. Because
-- the resolutions RLS allows a user to read their COMPANY's rows (user_id = me OR
-- company_id = mine), a company peer could `select steps_snapshot from resolutions`
-- and read fixes a colleague paid for — bypassing per-user pay-as-you-go and
-- undermining the 0010 lock.
--
-- Fix: revoke the blanket SELECT and re-grant every resolutions column EXCEPT
-- steps_snapshot. Safe — nothing reads steps_snapshot via PostgREST today
-- (writes happen in SECURITY DEFINER RPCs / the service-role unlock endpoint,
-- which bypass column grants). If a "my purchased fixes" view is built later, it
-- must read the snapshot through a gated RPC scoped to the caller's OWN
-- resolutions, not a direct table select.
-- ============================================================================

revoke select on resolutions from authenticated;

grant select (
  id, user_id, company_id, error_code, error_text, screen_name, ifs_version_hint,
  match_confidence, account_type_at_resolution, solution_id, solution_version,
  state, outcome, price_cents, stripe_payment_intent, activity, created_at, updated_at
) on resolutions to authenticated;

-- steps_snapshot deliberately omitted above — that's the lock.
-- Reverse (emergency): grant select (steps_snapshot) on resolutions to authenticated;
