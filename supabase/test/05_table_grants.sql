-- ============================================================================
-- LOCAL TEST HARNESS ONLY. Replicates the base table privileges Supabase grants
-- to anon/authenticated by default. RLS (from 0003) then restricts row access on
-- top of these grants — the grants alone open nothing that a policy doesn't allow.
-- ============================================================================

grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage, select on all sequences in schema public to authenticated;
