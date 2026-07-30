-- ============================================================================
-- Marketplace redesign · Stage 3 — dispute → admin arbitrates.
-- (Run after 0034.)
--
-- Revise-and-resubmit is already covered: deliver_fix accepts the
-- 'revision_requested' state, so a consultant just re-delivers. This stage adds
-- the escalation for when they DON'T agree with the rejection:
--   raise_dispute        — consultant insists the fix works → 'disputed'.
--   admin_arbitrate_uphold — admin sides with the consultant → 'confirmed'
--                            (credit available). Siding with the USER = refund,
--                            which reuses the existing consultant-refund flow.
--   admin_close_job (updated) — derived-credit aware: refund/reject is just a
--                            state change now; a refunded/rejected job simply
--                            stops counting toward available credit.
-- ============================================================================

-- ── Consultant escalates a rejection they disagree with ──────────────────────
create or replace function raise_dispute(p_job_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); j marketplace_jobs%rowtype;
begin
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.consultant_id <> v_user then raise exception 'not your job'; end if;
  if j.state <> 'revision_requested' then raise exception 'only a rejected fix can be disputed'; end if;

  update marketplace_jobs set state = 'disputed',
         user_note = coalesce(nullif(btrim(coalesce(p_note,'')),''), user_note), updated_at = now()
   where id = p_job_id;
  insert into notifications (user_id, type, title, body, data)
    select id, 'dispute', 'A fix is disputed',
           'A consultant disputed a rejected fix — please arbitrate in Marketplace.',
           jsonb_build_object('job_id', p_job_id)
      from users where role = 'platform_admin';
end $$;
grant execute on function raise_dispute(uuid, text) to authenticated;

-- ── Admin sides with the consultant → fix stands, credit becomes available ───
create or replace function admin_arbitrate_uphold(p_job_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; v_owner uuid;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;
  if j.state <> 'disputed' then raise exception 'job is not disputed'; end if;

  update marketplace_jobs set state = 'confirmed', confirmed_at = now(), updated_at = now() where id = p_job_id;
  update resolutions set state = 'resolved_confirmed', updated_at = now() where id = j.resolution_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications (user_id, type, title, body, data) values
    (j.consultant_id, 'dispute_upheld', 'Dispute resolved in your favor',
     'We reviewed the dispute — your fix stands and your credit is now available.',
     jsonb_build_object('job_id', p_job_id)),
    (v_owner, 'dispute_closed', 'Update on your issue',
     'We reviewed the fix you flagged; after review it stands. Reach out if you still need help.',
     jsonb_build_object('job_id', p_job_id));
end $$;
grant execute on function admin_arbitrate_uphold(uuid) to authenticated;

-- ── admin_close_job: derived-credit aware (refund = state change, no ledger) ──
-- The consultant-refund endpoint calls this after issuing the Stripe refund.
create or replace function admin_close_job(p_job_id uuid, p_refunded boolean)
returns void language plpgsql security definer set search_path = public as $$
declare j marketplace_jobs%rowtype; v_owner uuid;
begin
  if not is_platform_admin() then raise exception 'platform_admin required'; end if;
  select * into j from marketplace_jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;

  update marketplace_jobs set state = case when p_refunded then 'refunded' else 'rejected' end,
         updated_at = now() where id = p_job_id;
  update resolutions set state = case when p_refunded then 'refunded' else 'resolved_disputed' end,
         updated_at = now() where id = j.resolution_id;
  select user_id into v_owner from resolutions where id = j.resolution_id;
  insert into notifications (user_id, type, title, body, data)
    values (v_owner, case when p_refunded then 'refunded' else 'job_closed' end,
            case when p_refunded then 'Refund issued' else 'Update on your issue' end,
            case when p_refunded then 'We couldn''t deliver a verified fix, so your specialist payment has been refunded.'
                 else 'A specialist could not resolve this one — our team is following up.' end,
            jsonb_build_object('job_id', p_job_id));
end $$;
grant execute on function admin_close_job(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
