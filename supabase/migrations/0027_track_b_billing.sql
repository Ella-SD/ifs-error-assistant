-- ============================================================================
-- Track B billing support (scope v5, Part 16.2 + 16.4).
--   * track_b_response_days config (separate from escalation/marketplace SLA).
--   * propose_job_price uses it for the user-response deadline (keeps the 0026
--     self-dealing guard).
--   * deliver_job records the credited amount on the job (marketplace_jobs.credit_cents)
--     so a later refund can reverse it.
--   * admin_close_job pairs a refund with credit-revocation.
--   * my_priced_jobs(): the RPC that powers the user's "Approve & pay" screen —
--     returns pay_now_cents = proposed − already-paid-toward-this-error, i.e.
--     exactly what the consultant-charge endpoint will charge.
-- ============================================================================

alter table marketplace_jobs add column if not exists credit_cents int;

insert into app_config (key, value)
  values ('track_b_response_days', '7')
  on conflict (key) do nothing;

-- ── propose_job_price: 0026 guard + its own response window ───────────────────
create or replace function propose_job_price(p_job_id uuid, p_price_cents int)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype; v_days int; v_cap_mult int; v_owner uuid;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  if v_owner = v_user then raise exception 'you cannot claim your own job'; end if;
  if not _consultant_can_take(v_user, j.module) then raise exception 'not eligible for this job'; end if;
  if j.state <> 'open' then raise exception 'job is no longer open'; end if;
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

-- ── deliver_job: credit the consultant AND record how much (for reversal) ─────
create or replace function deliver_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; s solutions%rowtype; v_owner uuid;
        v_tier text; v_split int; v_fee int; v_credit int;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.state <> 'submitted' then raise exception 'job is not awaiting delivery'; end if;
  if j.solution_id is null then raise exception 'no submitted fix on this job'; end if;
  select * into s from solutions where id = j.solution_id;

  update resolutions set verified_steps = s.instructions, state='resolved_by_consultant', updated_at=now()
   where id = j.resolution_id;

  v_fee := coalesce(j.proposed_price_cents, j.base_price_cents);
  select tier into v_tier from consultant_profiles where user_id = j.consultant_id;
  select coalesce((select value::int from app_config
           where key = 'tier_split_' || coalesce(v_tier,'bronze')), 70) into v_split;
  v_credit := (v_fee * v_split) / 100;
  update consultant_profiles set credit_balance_cents = credit_balance_cents + v_credit, updated_at=now()
   where user_id = j.consultant_id;

  update marketplace_jobs set state='delivered', credit_cents = v_credit, updated_at=now() where id=p_job_id;

  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner,'delivered','Your verified fix is ready',
            'A specialist resolved your issue — open "My fixes" to view it.',
            jsonb_build_object('job_id', p_job_id));
  insert into notifications(user_id,type,title,body,data)
    values (j.consultant_id,'job_paid','Job delivered — credit added',
            'Your fix was delivered. $' || to_char(v_credit/100.0,'FM999990.00') || ' added to your balance.',
            jsonb_build_object('job_id', p_job_id, 'credit_cents', v_credit));
end $$;

-- ── admin_close_job: refund pairs with credit-revocation ─────────────────────
create or replace function admin_close_job(p_job_id uuid, p_refunded boolean)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; v_owner uuid;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;

  -- If refunding a job whose consultant was already credited (delivered then
  -- disputed), reverse that credit — refund + revocation are one action.
  if p_refunded and j.credit_cents is not null and j.consultant_id is not null then
    update consultant_profiles set credit_balance_cents = credit_balance_cents - j.credit_cents, updated_at=now()
     where user_id = j.consultant_id;
  end if;

  update marketplace_jobs set state = case when p_refunded then 'refunded' else 'rejected' end,
         credit_cents = case when p_refunded then null else credit_cents end,
         updated_at=now() where id=p_job_id;
  update resolutions set state = case when p_refunded then 'refunded' else 'resolved_disputed' end,
         updated_at=now() where id = j.resolution_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications(user_id,type,title,body,data)
    values (v_owner, case when p_refunded then 'refunded' else 'job_closed' end,
            case when p_refunded then 'Refund issued' else 'Update on your issue' end,
            case when p_refunded then 'We couldn''t deliver a verified fix, so your consultant charge has been refunded.'
                 else 'A specialist could not resolve this one — our team is following up.' end,
            jsonb_build_object('job_id', p_job_id));
end $$;

-- ── my_priced_jobs(): the user's jobs awaiting their approve-and-pay ──────────
-- pay_now_cents == what the consultant-charge endpoint will charge (proposed
-- minus already-paid-toward-this-error). PAYG sees the delta, subscriber the full quote.
create or replace function my_priced_jobs()
returns table (job_id uuid, proposed_price_cents int, already_paid_cents int, pay_now_cents int,
               module text, error_code text, error_text text, created_at timestamptz, deadline_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  return query
    select j.id, j.proposed_price_cents, coalesce(r.price_cents,0),
           greatest(0, j.proposed_price_cents - coalesce(r.price_cents,0)),
           j.module, r.error_code, r.error_text, j.created_at, j.deadline_at
      from marketplace_jobs j
      join resolutions r on r.id = j.resolution_id
     where r.user_id = v_user and j.state = 'price_proposed'
     order by j.created_at desc;
end $$;
grant execute on function my_priced_jobs() to authenticated;
