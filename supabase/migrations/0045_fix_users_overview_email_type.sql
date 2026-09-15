-- ============================================================================
-- Fix: admin_users_overview() failed at runtime with
--   "structure of query does not match function result type
--    (returned character varying(255) does not match expected type text
--     in column 2)"
--
-- Cause: auth.users.email is character varying(255), but the function declares
-- column 2 (email) as text. RETURN QUERY enforces an EXACT type match against
-- the declared RETURNS TABLE, so the varchar/text difference raised 42804 and
-- the whole call 400'd — leaving the admin "Users" panel showing zero users
-- (the client silently falls back to an empty list on error). A plain SELECT of
-- the same query never trips this, which is why it worked in the SQL editor but
-- not through the function.
--
-- Fix: cast au.email to text explicitly (same treatment u.role::text already
-- has). Only auth.users.email is affected — public.users.email and
-- companies.name are already text.
-- ============================================================================

create or replace function admin_users_overview()
returns table (user_id uuid, email text, role text, company_name text,
               plan text, subscription_status text, subscribed boolean,
               payg_ready boolean, is_consultant boolean,
               email_confirmed boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select au.id,
           au.email::text,
           u.role::text,
           c.name,
           coalesce(u.plan, c.plan),
           coalesce(u.subscription_status, c.subscription_status),
           coalesce(has_active_subscription(au.id), false),
           coalesce(u.payg_ready, false),
           exists (select 1 from consultant_profiles cp where cp.user_id = au.id),
           (au.email_confirmed_at is not null),
           au.created_at
      from auth.users au
      left join users u     on u.id = au.id
      left join companies c on c.id = u.company_id
     where au.deleted_at is null
     order by au.created_at desc;
end $$;
grant execute on function admin_users_overview() to authenticated;

notify pgrst, 'reload schema';
