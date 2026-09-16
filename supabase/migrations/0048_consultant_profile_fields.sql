-- ============================================================================
-- Richer consultant application fields.
--
-- Previously a consultant application only captured modules. That makes it
-- impossible for the admin to validate identity or expertise — especially for
-- applicants who sign up with a throwaway email and no other context.
--
-- New fields:
--   full_name        — name to validate against LinkedIn / contact
--   country          — geographic context
--   years_experience — bucketed ('< 1 year', '1–3 years', etc.)
--   professional_url — LinkedIn or other professional profile (clickable in admin)
--   background_note  — free-text: "I specialize in MM/SCM at mid-size discrete mfg"
--   resume_url       — optional link to CV (Google Drive, Dropbox, etc.)
--
-- All new columns are nullable so existing rows are unaffected. The
-- apply_as_consultant RPC is updated to accept (and store) these values.
-- admin_consultant_applications is updated to return them so the admin can
-- review them in the Marketplace panel without a separate query.
-- ============================================================================

alter table consultant_profiles
  add column if not exists full_name        text,
  add column if not exists country          text,
  add column if not exists years_experience text,
  add column if not exists professional_url text,
  add column if not exists background_note  text,
  add column if not exists resume_url       text;

-- ── apply_as_consultant (updated) ──────────────────────────────────────────
create or replace function apply_as_consultant(
  p_modules          text[],
  p_full_name        text    default null,
  p_country          text    default null,
  p_years_experience text    default null,
  p_professional_url text    default null,
  p_background_note  text    default null,
  p_resume_url       text    default null
)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  insert into consultant_profiles
    (user_id, modules, status,
     full_name, country, years_experience,
     professional_url, background_note, resume_url)
  values
    (v_user, coalesce(p_modules, '{}'), 'pending',
     nullif(trim(coalesce(p_full_name, '')), ''),
     nullif(trim(coalesce(p_country, '')), ''),
     nullif(trim(coalesce(p_years_experience, '')), ''),
     nullif(trim(coalesce(p_professional_url, '')), ''),
     nullif(trim(coalesce(p_background_note, '')), ''),
     nullif(trim(coalesce(p_resume_url, '')), ''))
  on conflict (user_id) do update
    set modules          = excluded.modules,
        full_name        = coalesce(excluded.full_name,        consultant_profiles.full_name),
        country          = coalesce(excluded.country,          consultant_profiles.country),
        years_experience = coalesce(excluded.years_experience, consultant_profiles.years_experience),
        professional_url = coalesce(excluded.professional_url, consultant_profiles.professional_url),
        background_note  = coalesce(excluded.background_note,  consultant_profiles.background_note),
        resume_url       = coalesce(excluded.resume_url,       consultant_profiles.resume_url),
        updated_at       = now();
end $$;

-- ── admin_consultant_applications (updated) ────────────────────────────────
drop function if exists admin_consultant_applications();
create or replace function admin_consultant_applications()
returns table (
  user_id uuid, email text, modules text[], tier text, status text,
  credit_balance_cents int, confirmed_count int, refunded_count int, taken_count int,
  full_name text, country text, years_experience text,
  professional_url text, background_note text, resume_url text
)
language plpgsql stable security definer set search_path = public as $$
declare v_win int;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select coalesce((select value::int from app_config where key='marketplace_autoconfirm_days'), 7) into v_win;
  return query
    select cp.user_id, u.email, cp.modules, cp.tier, cp.status, cp.credit_balance_cents,
           coalesce(s.confirmed_count, 0), coalesce(s.refunded_count, 0), coalesce(s.taken_count, 0),
           cp.full_name, cp.country, cp.years_experience,
           cp.professional_url, cp.background_note, cp.resume_url
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

notify pgrst, 'reload schema';
