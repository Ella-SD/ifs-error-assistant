-- ============================================================================
-- LOCAL TEST HARNESS ONLY — not applied to the real Supabase project.
-- Stubs the pieces Supabase provides so the migrations can be exercised against
-- a plain local Postgres:
--   * anon / authenticated / service_role roles
--   * auth schema, auth.users table, auth.uid()
-- auth.uid() reads a session GUC so the harness can "log in" as different users:
--   select set_config('test.current_user_id', '<uuid>', false); set role authenticated;
-- Idempotent + run OUTSIDE the rolled-back test transaction so it persists.
-- ============================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);

-- Mirrors Supabase's auth.uid(): the current request's user id. Here it comes
-- from a session GUC instead of a JWT claim.
create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select nullif(current_setting('test.current_user_id', true), '')::uuid
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;
