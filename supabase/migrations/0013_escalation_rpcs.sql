-- ============================================================================
-- Manual rejected-fix escalation — RPCs + config (canonical scope Part 13 + 13.4).
--
-- Runs AFTER 0012 (which added the enum values; Postgres won't let a new enum
-- value be used in the same transaction it's created, hence the split).
--
-- Flow: user 👎 → escalate_resolution (records the down outcome, moves the row to
-- 'escalated', stores optional context) → admin works the queue via
-- admin_escalations() → admin_resolve_escalation() marks it resolved-by-consultant
-- or refunded. Refunds themselves are done by hand in Stripe (13.4 #5); this just
-- records the outcome so it isn't handled twice. No scheduler, no notifications.
-- ============================================================================

-- Configurable "overdue" window (13.4 #2) — a display flag only, never automatic.
insert into app_config(key, value) values ('escalation_sla_days', '7')
  on conflict (key) do nothing;

-- ── User escalates their own rejected resolution (the 👎 path) ────────────────
-- Records the down outcome + the reject count, moves to 'escalated', and stores
-- the optional "what went wrong / what were you trying to do" context (Part 9.3).
create or replace function escalate_resolution(p_resolution_id uuid, p_context text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); r resolutions%rowtype;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  select * into r from resolutions where id = p_resolution_id and user_id = v_user for update;
  if not found then raise exception 'resolution not found'; end if;

  update resolutions
     set outcome    = 'down',
         state      = 'escalated',
         activity   = nullif(btrim(coalesce(p_context, '')), ''),
         updated_at = now()
   where id = p_resolution_id;

  if r.solution_id is not null then
    update solutions set times_rejected = times_rejected + 1 where id = r.solution_id;
  end if;
end $$;

-- ── Admin escalation queue ───────────────────────────────────────────────────
-- Platform-admin only. Deliberately crosses the "no admin escape hatch on
-- resolution error-data" posture, but ONLY for escalated rows (the user opted in
-- by asking for review). Exposes extracted text + context + the failed fix +
-- user email + the Stripe payment ref so a refund is one click. No screenshots
-- (they're never stored). price_cents>0 marks a refundable (PAYG/assemble) case.
create or replace function admin_escalations()
returns table (
  id                 uuid,
  created_at         timestamptz,
  updated_at         timestamptz,
  state              resolution_state,
  error_code         text,
  error_text         text,
  screen_name        text,
  activity           text,
  match_confidence   text,
  account_type       text,
  price_cents        int,
  stripe_payment_intent text,
  solution_title     text,
  user_email         text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  return query
    select r.id, r.created_at, r.updated_at, r.state,
           r.error_code, r.error_text, r.screen_name, r.activity,
           r.match_confidence, r.account_type_at_resolution, r.price_cents, r.stripe_payment_intent,
           s.title, u.email
      from resolutions r
      left join solutions s on s.id = r.solution_id
      left join users u     on u.id = r.user_id
     where r.state in ('escalated', 'resolved_by_consultant', 'refunded')
     order by (r.state = 'escalated') desc, r.updated_at desc;
end $$;

-- ── Admin closes out an escalation ───────────────────────────────────────────
-- p_refunded=true → 'refunded' (admin has already refunded in Stripe);
-- p_refunded=false → 'resolved_by_consultant' (a verified fix was delivered).
create or replace function admin_resolve_escalation(p_resolution_id uuid, p_refunded boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  update resolutions
     set state = (case when p_refunded then 'refunded' else 'resolved_by_consultant' end)::resolution_state,
         updated_at = now()
   where id = p_resolution_id
     and state in ('escalated', 'resolved_by_consultant', 'refunded');
end $$;

grant execute on function escalate_resolution(uuid, text)        to authenticated;
grant execute on function admin_escalations()                    to authenticated;
grant execute on function admin_resolve_escalation(uuid, boolean) to authenticated;
