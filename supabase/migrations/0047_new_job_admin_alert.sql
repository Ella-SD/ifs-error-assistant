-- ============================================================================
-- New-job admin alert.
--
-- When a marketplace job is created (a user escalates an error → a row is
-- INSERTed into marketplace_jobs in state 'open'), ping the proxy, which emails
-- admin@ifsguru.com via Brevo. Lets the operator know work is waiting without
-- having to watch the app — important while consultant supply is thin.
--
-- Mirrors 0042 (signup alert) / 0046 (welcome email): pg_net fire-and-forget,
-- gated by the same shared secret. Fetches the error code/text from the linked
-- resolution so the email is useful at a glance.
--
-- INSERT only: a job that REOPENS after a declined quote is an UPDATE, not an
-- INSERT, so it won't re-alert — the initial escalation is the event that
-- matters. The reopened job still shows in the admin/consultant job lists.
-- ============================================================================

create extension if not exists pg_net;

create or replace function public.notify_admin_on_new_job()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_error_code text; v_error_text text;
begin
  select r.error_code, r.error_text
    into v_error_code, v_error_text
    from resolutions r
   where r.id = NEW.resolution_id;

  perform net.http_post(
    url     := 'https://ifs-error-assistant-proxy.vercel.app/api/notify-signup',
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'x-signup-secret', 'bee081174bb0e7a8f3fea853a4db14df548da0d2591492b9'
    ),
    body    := jsonb_build_object('record', jsonb_build_object(
      'job_id',     NEW.id,
      'module',     NEW.module,
      'error_code', v_error_code,
      'error_text', v_error_text
    ))
  );
  return NEW;
end $$;

drop trigger if exists on_marketplace_job_created on marketplace_jobs;
create trigger on_marketplace_job_created
  after insert on marketplace_jobs
  for each row
  when (new.state = 'open')
  execute function public.notify_admin_on_new_job();
