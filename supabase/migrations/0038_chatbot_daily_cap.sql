-- ============================================================================
-- "Ask a question" (Q&A chatbot) daily free-question cap.
--
-- The chat is free and intentionally general — it gives orientation and routes
-- users to the PAID Troubleshoot/Search for actual fixes. But every message
-- costs us an Anthropic call + a web search, so an uncapped free feature could
-- run up unbounded cost if abused. This adds a per-user daily ceiling.
--
--   * Limit is config-driven (app_config.chatbot_daily_limit), default 10.
--   * platform_admins are exempt (testing / support).
--   * Counter is per user per calendar day; nothing to clean up (old rows are
--     harmless and can be pruned later if desired).
-- ============================================================================

insert into app_config(key, value) values ('chatbot_daily_limit', '10')
  on conflict (key) do nothing;

create table if not exists chatbot_daily_usage (
  user_id    uuid    not null references auth.users(id) on delete cascade,
  usage_date date    not null default current_date,
  count      int     not null default 0,
  primary key (user_id, usage_date)
);
alter table chatbot_daily_usage enable row level security;
-- No RLS policies on purpose: only the SECURITY DEFINER function below touches
-- this table, so end users can't read or tamper with their own counts.

-- Atomically checks today's usage against the limit and, if under, increments.
-- Returns { allowed, remaining, limit }. Call once per chat message BEFORE
-- hitting the AI; only send the message when allowed = true.
create or replace function use_chatbot_quota()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_limit int; v_count int;
begin
  if v_user is null then raise exception 'not authenticated'; end if;

  -- Admins are never capped.
  if is_platform_admin() then
    return jsonb_build_object('allowed', true, 'remaining', 9999, 'limit', 9999);
  end if;

  select coalesce((select value::int from app_config where key = 'chatbot_daily_limit'), 10)
    into v_limit;

  select count into v_count from chatbot_daily_usage
    where user_id = v_user and usage_date = current_date;
  v_count := coalesce(v_count, 0);

  if v_count >= v_limit then
    return jsonb_build_object('allowed', false, 'remaining', 0, 'limit', v_limit);
  end if;

  insert into chatbot_daily_usage (user_id, usage_date, count)
    values (v_user, current_date, 1)
    on conflict (user_id, usage_date)
      do update set count = chatbot_daily_usage.count + 1;

  return jsonb_build_object('allowed', true, 'remaining', v_limit - (v_count + 1), 'limit', v_limit);
end $$;
grant execute on function use_chatbot_quota() to authenticated;
