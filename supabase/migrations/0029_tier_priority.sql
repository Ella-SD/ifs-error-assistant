-- ============================================================================
-- Consultant tier priority + tier badge on quotes.
--
-- Two small trust/quality touches on top of quote-first:
--   1) Priority window — higher-tier specialists get first crack at a new job.
--      A job opens to gold immediately, silver after 1 step, bronze after 2
--      (step = tier_priority_step_min, default 15 min). Everyone still SEES the
--      job (the client shows a countdown); only the ability to QUOTE is gated,
--      enforced here in propose_job_price so the client can't bypass it. No
--      scheduler needed — it's a function of the job's age.
--   2) my_priced_jobs() now returns the quoting consultant's tier, so the user's
--      "Approve & pay" card can show a Gold/Silver/Bronze badge as a trust signal.
-- ============================================================================

insert into app_config(key, value) values ('tier_priority_step_min', '15')
  on conflict (key) do nothing;

-- gold = first (0), silver = 1 step, bronze / unknown = 2 steps.
create or replace function _tier_rank(p_tier text)
returns int language sql immutable as $$
  select case lower(coalesce(p_tier, ''))
           when 'gold' then 0 when 'silver' then 1 when 'bronze' then 2 else 2 end;
$$;
grant execute on function _tier_rank(text) to authenticated;

-- ── propose_job_price: keep every existing guard, add the tier priority window ─
create or replace function propose_job_price(p_job_id uuid, p_price_cents int)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype;
        v_days int; v_cap_mult int; v_owner uuid; v_tier text; v_step int; v_wait int;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner = v_user then raise exception 'you cannot claim your own job'; end if;   -- self-dealing guard
  if not _consultant_can_take(v_user, j.module) then raise exception 'not eligible for this job'; end if;
  if j.state <> 'open' then raise exception 'job is no longer open'; end if;

  -- Tier priority: this job may not be open to the caller's tier yet.
  select tier into v_tier from consultant_profiles where user_id = v_user;
  select coalesce((select value::int from app_config where key='tier_priority_step_min'), 15) into v_step;
  v_wait := _tier_rank(v_tier) * v_step * 60;   -- seconds
  if extract(epoch from (now() - j.created_at)) < v_wait then
    raise exception 'higher-tier specialists get first access to new jobs — this one opens to your tier shortly';
  end if;

  select coalesce((select value::int from app_config where key='trackb_cap_multiplier'), 5) into v_cap_mult;
  if p_price_cents < j.base_price_cents or p_price_cents > j.base_price_cents * v_cap_mult then
    raise exception 'proposed price out of allowed range';
  end if;
  select coalesce((select value::int from app_config where key='track_b_response_days'), 7) into v_days;
  update marketplace_jobs
     set consultant_id=v_user, proposed_price_cents=p_price_cents, state='price_proposed',
         claimed_at=now(), deadline_at = now() + make_interval(days => v_days), updated_at=now()
   where id = p_job_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'price_proposed','A price came back for your issue',
            'A specialist can take this for $' || to_char(p_price_cents/100.0,'FM999990.00') || '. Approve to proceed.',
            jsonb_build_object('job_id', p_job_id, 'price_cents', p_price_cents));
end $$;
grant execute on function propose_job_price(uuid, int) to authenticated;

-- ── my_priced_jobs(): now also returns the quoting consultant's tier ──────────
-- Return type changed (added consultant_tier), so drop the 0027 version first —
-- CREATE OR REPLACE cannot alter an existing function's OUT columns.
drop function if exists my_priced_jobs();
create or replace function my_priced_jobs()
returns table (job_id uuid, proposed_price_cents int, already_paid_cents int, pay_now_cents int,
               module text, error_code text, error_text text, created_at timestamptz, deadline_at timestamptz,
               consultant_tier text)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.proposed_price_cents, coalesce(r.price_cents,0),
           greatest(0, j.proposed_price_cents - coalesce(r.price_cents,0)),
           j.module, r.error_code, r.error_text, j.created_at, j.deadline_at,
           cp.tier
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
      left join consultant_profiles cp on cp.user_id = j.consultant_id
     where r.user_id = v_user and j.state = 'price_proposed'
     order by j.created_at desc;
end $$;
grant execute on function my_priced_jobs() to authenticated;
