-- ============================================================================
-- LOCAL TEST HARNESS ONLY — orchestrator.
-- Run against a throwaway local Postgres:  psql -f supabase/test/run_all.sql
-- Roles/auth stub persist; schema + data live inside a transaction that is
-- ROLLED BACK at the end, so every run starts clean and mutates nothing durable.
-- ============================================================================
\set ON_ERROR_STOP on

\ir 00_roles_auth.sql

begin;
  \ir ../migrations/0001_schema.sql
  \ir ../migrations/0002_functions.sql
  \ir ../migrations/0003_rls.sql
  \ir ../migrations/0004_assembled_sources.sql
  \ir ../migrations/0005_archive_context.sql
  \ir ../seed.sql
  \ir 05_table_grants.sql
  \ir 20_tests.sql
rollback;
