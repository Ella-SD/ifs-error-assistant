-- ============================================================================
-- Admin "Users" overview — surface every end user in one admin-only list.
--
-- Consultants already have an approval screen (admin_consultant_applications);
-- end users had no in-app visibility at all — you had to open the Supabase
-- dashboard. This gives the admin tab a plain list of who signed up, when, and
-- whether they're paying.
--
-- effective plan/subscription looks at BOTH the personal columns (users) and the
-- company columns (companies) — a company_member is "subscribed" via their
-- company's plan, mirroring has_active_subscription().
-- ============================================================================

drop function if exists admin_users_overview();
create or replace function admin_users_overview()
returns table (user_id uuid, email text, role text, company_name text,
               plan text, subscription_status text, subscribed boolean,
               payg_ready boolean, is_consultant boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select u.id, u.email, u.role::text, c.name,
           coalesce(u.plan, c.plan),
           coalesce(u.subscription_status, c.subscription_status),
           has_active_subscription(u.id),
           u.payg_ready,
           exists (select 1 from consultant_profiles cp where cp.user_id = u.id),
           u.created_at
      from users u
      left join companies c on c.id = u.company_id
     order by u.created_at desc;
end $$;
grant execute on function admin_users_overview() to authenticated;
