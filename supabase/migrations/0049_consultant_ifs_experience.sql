-- ============================================================================
-- Consultant application: direct IFS / IFS-Partner experience flag.
--
-- "Have you worked for IFS AB or an IFS Partner as a consultant?" (yes/no)
-- and, if yes, how many years.  Strong positive signal for tier assignment.
-- ============================================================================

alter table consultant_profiles
  add column if not exists worked_for_ifs      boolean,   -- true = yes, false = no, null = not answered
  add column if not exists ifs_partner_years   text;      -- e.g. '1–3 years', null when worked_for_ifs is false

-- ── Storage bucket for consultant resume uploads ───────────────────────────
-- Public read so the admin can click the link without auth. Files are stored
-- under {user_id}/{uuid}-{filename} — path is not guessable from outside.
insert into storage.buckets (id, name, public)
  values ('consultant-resumes', 'consultant-resumes', true)
  on conflict (id) do nothing;

-- Only the file owner can upload/replace their own resume.
-- Anyone (including unauthenticated links the admin clicks) can read.
create policy "owner upload" on storage.objects for insert
  with check (bucket_id = 'consultant-resumes' and auth.uid()::text = (string_to_array(name, '/'))[1]);

create policy "owner update" on storage.objects for update
  using (bucket_id = 'consultant-resumes' and auth.uid()::text = (string_to_array(name, '/'))[1]);

create policy "owner delete" on storage.objects for delete
  using (bucket_id = 'consultant-resumes' and auth.uid()::text = (string_to_array(name, '/'))[1]);

create policy "public read" on storage.objects for select
  using (bucket_id = 'consultant-resumes');

-- ── apply_as_consultant (updated again) ──────────────────────────────────
create or replace function apply_as_consultant(
  p_modules             text[],
  p_full_name           text    default null,
  p_country             text    default null,
  p_years_experience    text    default null,
  p_professional_url    text    default null,
  p_background_note     text    default null,
  p_resume_url          text    default null,
  p_worked_for_ifs      boolean default null,
  p_ifs_partner_years   text    default null
)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  insert into consultant_profiles
    (user_id, modules, status,
     full_name, country, years_experience,
     professional_url, background_note, resume_url,
     worked_for_ifs, ifs_partner_years)
  values
    (v_user, coalesce(p_modules, '{}'), 'pending',
     nullif(trim(coalesce(p_full_name, '')), ''),
     nullif(trim(coalesce(p_country, '')), ''),
     nullif(trim(coalesce(p_years_experience, '')), ''),
     nullif(trim(coalesce(p_professional_url, '')), ''),
     nullif(trim(coalesce(p_background_note, '')), ''),
     nullif(trim(coalesce(p_resume_url, '')), ''),
     p_worked_for_ifs,
     case when p_worked_for_ifs then nullif(trim(coalesce(p_ifs_partner_years, '')), '') else null end)
  on conflict (user_id) do update
    set modules            = excluded.modules,
        full_name          = coalesce(excluded.full_name,          consultant_profiles.full_name),
        country            = coalesce(excluded.country,            consultant_profiles.country),
        years_experience   = coalesce(excluded.years_experience,   consultant_profiles.years_experience),
        professional_url   = coalesce(excluded.professional_url,   consultant_profiles.professional_url),
        background_note    = coalesce(excluded.background_note,    consultant_profiles.background_note),
        resume_url         = coalesce(excluded.resume_url,         consultant_profiles.resume_url),
        worked_for_ifs     = coalesce(excluded.worked_for_ifs,     consultant_profiles.worked_for_ifs),
        ifs_partner_years  = coalesce(excluded.ifs_partner_years,  consultant_profiles.ifs_partner_years),
        updated_at         = now();
end $$;

-- ── admin_consultant_applications (updated again) ─────────────────────────
drop function if exists admin_consultant_applications();
create or replace function admin_consultant_applications()
returns table (
  user_id uuid, email text, modules text[], tier text, status text,
  credit_balance_cents int, confirmed_count int, refunded_count int, taken_count int,
  full_name text, country text, years_experience text,
  professional_url text, background_note text, resume_url text,
  worked_for_ifs boolean, ifs_partner_years text
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
           cp.professional_url, cp.background_note, cp.resume_url,
           cp.worked_for_ifs, cp.ifs_partner_years
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
