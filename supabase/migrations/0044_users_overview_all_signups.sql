-- ============================================================================
-- Admin Users overview — show ALL signups, not just onboarded ones.
--
-- The previous version (0041) sourced from public.users, which only holds users
-- who completed onboarding. Anyone who signed up but never confirmed their email
-- was invisible in the admin panel (they live in auth.users only). This rebases
-- the list on auth.users (LEFT JOIN public.users), so every signup shows up, and
-- adds an `email_confirmed` flag so the admin can spot — and manually confirm —
-- stuck leads.
-- ============================================================================

drop function if exists admin_users_overview();
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
           au.email,
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
