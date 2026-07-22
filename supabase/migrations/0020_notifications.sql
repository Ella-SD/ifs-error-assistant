-- ============================================================================
-- Marketplace v1 · Phase 0 — in-app notifications.
--
-- The reactive channel: consultants get pinged when a matching-module job appears
-- (scope 13.6 #2), and users get status updates. Email layers on top later
-- (Phase 2, needs SMTP). Notifications are created by other SECURITY DEFINER RPCs
-- / the Phase 2 scheduler via notify(); end users only read + mark-read their own.
-- ============================================================================

create table if not exists notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users(id) on delete cascade,
  type       text not null,        -- job_available | price_proposed | delivered | refunded | ...
  title      text not null,
  body       text,
  data       jsonb,                -- e.g. { "job_id": ..., "resolution_id": ... }
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on notifications(user_id, created_at desc);

alter table notifications enable row level security;
-- Read your own only. No direct write policy — inserts happen via notify()
-- (definer) and mark-read via the RPC below.
create policy notif_own_read on notifications for select using (user_id = auth.uid());

-- Internal: create a notification. NOT granted to end users (called by other
-- definer RPCs and the Phase 2 scheduler).
create or replace function notify(p_user uuid, p_type text, p_title text, p_body text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  insert into notifications (user_id, type, title, body, data)
    values (p_user, p_type, p_title, p_body, p_data);
end $$;

-- Client: mark my notifications read.
create or replace function mark_notifications_read(p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  update notifications set read_at = now()
   where user_id = auth.uid() and id = any (p_ids) and read_at is null;
end $$;

grant execute on function mark_notifications_read(uuid[]) to authenticated;
-- notify(...) intentionally NOT granted to authenticated — internal use only.
