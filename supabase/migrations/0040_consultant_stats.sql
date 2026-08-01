-- ============================================================================
-- Per-consultant track-record stats on the admin applications list.
--
-- Tiering stays MANUAL (admin picks bronze/silver/gold), but this surfaces the
-- quality signal so the decision is data-informed:
--   * confirmed = fixes that succeeded (user 👍 OR auto-confirmed past the window)
--   * refunded  = fixes that ultimately failed / lost a dispute (the negative signal)
--   * taken     = total jobs they actually worked (activity/volume)
-- Return columns change → drop + recreate.
-- ============================================================================

drop function if exists admin_consultant_applications();
create or replace function admin_consultant_applications()
returns table (user_id uuid, email text, modules text[], tier text, status text, credit_balance_cents int,
               confirmed_count int, refunded_count int, taken_count int)
language plpgsql stable security definer set search_path = public as $$
declare v_win int;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select coalesce((select value::int from app_config where key='marketplace_autoconfirm_days'), 7) into v_win;
  return query
    select cp.user_id, u.email, cp.modules, cp.tier, cp.status, cp.credit_balance_cents,
           coalesce(s.confirmed_count, 0), coalesce(s.refunded_count, 0), coalesce(s.taken_count, 0)
      from consultant_profiles cp
      join users u on u.id = cp.user_id
      left join lateral (
        select
          count(*) filter (where j.state = 'confirmed'
             or (j.state = 'delivered' and j.delivered_at <= now() - make_interval(days => v_win)))::int as confirmed_count,
          count(*) filter (where j.state = 'refunded')::int as refunded_count,
          count(*) filter (where j.state in ('in_progress','delivered','confirmed','revision_requested','disputed','refunded'))::int as taken_count
        from marketplace_jobs j
        where j.consultant_id = cp.user_id
      ) s on true
     order by (cp.status = 'pending') desc, cp.updated_at desc;
end $$;
grant execute on function admin_consultant_applications() to authenticated;
