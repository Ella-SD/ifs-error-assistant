-- ============================================================================
-- Steps-column lock — the FINAL step of the paid-resolution rework.
--
-- End users must never be able to read solution steps directly; steps are served
-- ONLY through the gated paths (the SECURITY DEFINER reveal_solution RPC for
-- subscribers/admin, and the service-role /api/billing/unlock endpoint for PAYG).
-- Column-level UI hiding isn't enough — a hand-crafted PostgREST query could still
-- pull `solutions.instructions`. This revokes SELECT on that one column from the
-- `authenticated` role.
--
-- MUST run LAST, only after the deployed app has stopped selecting `instructions`
-- client-side (loadLibrary is metadata-only; insertSolution returns metadata only;
-- admins read full rows via admin_solutions_with_steps). Running it earlier would
-- break the live app mid-rollout.
--
-- How the lock works (same shape as 0006's column-level UPDATE lock): drop the
-- blanket table SELECT, then re-grant SELECT on every column EXCEPT instructions.
-- The SECURITY DEFINER RPCs and the service-role endpoint run as the table owner,
-- so they bypass this grant and keep working. RLS still filters which ROWS are
-- visible; this filters which COLUMN is.
-- ============================================================================

revoke select on solutions from authenticated;

grant select (
  id, error_code, lu_name, package_name, component_code, component_name,
  error_template, ifs_version, title, who_acts, status, source, reject_note,
  times_served, times_accepted, times_rejected, contributed_by_user_id,
  last_verified, published_at, created_at, assembled_sources, version
) on solutions to authenticated;

-- Note: `instructions` is deliberately omitted above — that's the lock.
-- To reverse (e.g. emergency rollback): grant select (instructions) on solutions to authenticated;
