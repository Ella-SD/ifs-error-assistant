-- ============================================================================
-- LOCAL TEST HARNESS ONLY — RLS / RPC behavioural assertions.
-- Runs inside the rolled-back transaction started by run_all.sql.
-- Any failed assert aborts psql (ON_ERROR_STOP), so reaching the final banner
-- means everything passed.
--
-- psql note: :'var' is NOT interpolated inside DO $$...$$ bodies, so fixture ids
-- are pushed into session GUCs (test.*) and read with current_setting() inside
-- assertion blocks. "Log in" = set test.current_user_id then `set role
-- authenticated`; `reset role` returns to superuser for fixture setup.
-- ============================================================================

-- ── Fixtures ────────────────────────────────────────────────────────────────
insert into auth.users(email) values ('alice@acme.test')     returning id as alice_id \gset
insert into auth.users(email) values ('bob@acme.test')       returning id as bob_id   \gset
insert into auth.users(email) values ('carol@globex.test')   returning id as carol_id \gset
insert into auth.users(email) values ('dave@platform.test')  returning id as dave_id  \gset

-- Alice self-signs-up company A (exercises create_company_and_join RPC)
select set_config('test.current_user_id', :'alice_id', false);
set role authenticated;
select create_company_and_join('Acme Manufacturing', 'IFS10') as company_a_id \gset
reset role;

-- Carol self-signs-up company B
select set_config('test.current_user_id', :'carol_id', false);
set role authenticated;
select create_company_and_join('Globex', 'IFS10') as company_b_id \gset
reset role;

-- Dave promoted to platform_admin by manual grant (real flow: a direct DB update
-- to your own account — there is no signup path to this role)
insert into users(id, email, company_id, role)
  values (:'dave_id', 'dave@platform.test', null, 'platform_admin');

-- Alice invites Bob; Bob accepts (exercises invite + accept_company_invite RPC)
select set_config('test.current_user_id', :'alice_id', false);
set role authenticated;
insert into company_invites(company_id, email, role, created_by)
  values (:'company_a_id', 'bob@acme.test', 'company_member', :'alice_id');
reset role;

select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;
select accept_company_invite();
-- Bob adds a legitimate DRAFT of his own (used by the review-gate tests)
insert into solutions(error_code, title, status, contributed_by_user_id)
  values ('DRAFTCODE', 'my draft fix', 'DRAFT', :'bob_id') returning id as draft_id \gset
reset role;

-- The one PUBLISHED seed solution
select id as seed1_id from solutions where error_code = 'DELETENOTPERMITTED' limit 1 \gset

-- Push every id used inside DO blocks into GUCs
select set_config('test.alice_id',     :'alice_id',     false);
select set_config('test.bob_id',       :'bob_id',       false);
select set_config('test.carol_id',     :'carol_id',     false);
select set_config('test.company_a_id', :'company_a_id', false);
select set_config('test.seed1_id',     :'seed1_id',     false);
select set_config('test.draft_id',     :'draft_id',     false);

-- Onboarding sanity
do $$ begin
  assert (select role from users where id = current_setting('test.alice_id')::uuid) = 'company_admin',  'S1: alice is company_admin';
  assert (select role from users where id = current_setting('test.bob_id')::uuid)   = 'company_member', 'S2: bob is company_member';
  assert (select company_id from users where id = current_setting('test.bob_id')::uuid) = current_setting('test.company_a_id')::uuid, 'S3: bob joined company A';
  assert (select accepted_at is not null from company_invites where email = 'bob@acme.test'), 'S4: invite marked accepted';
end $$;

-- ══ A. Archive isolation + platform_admin asymmetry ═════════════════════════
select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;
insert into archive_entries(company_id, submitted_by_user_id, error_text, screen_name)
  values (:'company_a_id', :'bob_id', 'Secret order #12345 for Customer Foo', 'Customer Order');
do $$ begin
  assert (select count(*) from archive_entries) = 1, 'A1: bob sees his own company archive';
end $$;
reset role;

select set_config('test.current_user_id', :'carol_id', false);
set role authenticated;
do $$ begin
  assert (select count(*) from archive_entries) = 0, 'A2: carol (company B) must NOT see company A archive';
end $$;
reset role;

select set_config('test.current_user_id', :'dave_id', false);
set role authenticated;
do $$ begin
  assert (select count(*) from archive_entries) = 0,
    'A3: platform_admin must NOT see any company archive (deliberate asymmetry)';
end $$;
reset role;

-- ══ B. Solutions are shared platform-wide ═══════════════════════════════════
-- (bob has his own DRAFT now, so he sees the 1 live seed + his own draft = 2)
select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;
do $$ begin
  assert (select count(*) from solutions where status in ('PUBLISHED','VERIFIED','NEEDS_REVIEW')) = 1,
    'B1: exactly 1 live seed visible (9 NO_INSTRUCTION rows hidden)';
  assert (select count(*) from solutions) = 2,
    'B1b: bob additionally sees his own non-live draft, nothing else';
end $$;
reset role;

select set_config('test.current_user_id', :'carol_id', false);
set role authenticated;
do $$ begin
  assert (select count(*) from solutions
            where error_code = 'DELETENOTPERMITTED' and status = 'PUBLISHED') = 1,
    'B2: the SAME shared solution is visible to a different company';
  assert not exists (select 1 from solutions where error_code = 'DRAFTCODE'),
    'B2b: carol cannot see bob''s private draft';
end $$;
reset role;

-- ══ C. Review gate (item 5) ═════════════════════════════════════════════════
select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;

-- C1: non-admin cannot INSERT a row already PUBLISHED
do $$ begin
  begin
    insert into solutions(error_code, title, status, contributed_by_user_id)
      values ('HACKCODE', 'pwned', 'PUBLISHED', current_setting('test.bob_id')::uuid);
    raise exception 'C1 FAILED: non-admin inserted a PUBLISHED solution';
  exception when insufficient_privilege then
    raise notice 'C1 OK: direct insert of PUBLISHED denied';
  end;
end $$;

-- C3: bob cannot self-publish his own draft via direct UPDATE (WITH CHECK caps non-live)
do $$ begin
  begin
    update solutions set status = 'PUBLISHED' where id = current_setting('test.draft_id')::uuid;
    raise exception 'C3 FAILED: bob self-published his own draft';
  exception when insufficient_privilege then
    raise notice 'C3 OK: self-publish via update denied';
  end;
end $$;

-- C4: bob CAN submit his own draft for review (DRAFT -> PENDING_REVIEW)
update solutions set status = 'PENDING_REVIEW' where id = :'draft_id';
do $$ begin
  assert (select status from solutions where id = current_setting('test.draft_id')::uuid) = 'PENDING_REVIEW',
    'C4: bob submitted own draft for review';
end $$;

-- C5: bob cannot approve via the moderation RPC
do $$ begin
  begin
    perform moderate_solution(current_setting('test.draft_id')::uuid, 'approve');
    raise exception 'C5 FAILED: non-admin approved via RPC';
  exception when others then
    if sqlerrm like '%platform_admin%' then raise notice 'C5 OK: moderation RPC rejected non-admin';
    else raise;
    end if;
  end;
end $$;
reset role;

-- C6: platform_admin approves -> PUBLISHED + published_at set
select set_config('test.current_user_id', :'dave_id', false);
set role authenticated;
select moderate_solution(:'draft_id', 'approve');
do $$ begin
  assert (select status from solutions where id = current_setting('test.draft_id')::uuid) = 'PUBLISHED', 'C6: admin approve -> PUBLISHED';
  assert (select published_at is not null from solutions where id = current_setting('test.draft_id')::uuid), 'C6b: published_at stamped';
end $$;
reset role;

-- ══ D. Feedback path is tamper-resistant ════════════════════════════════════
select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;

-- D1: positive feedback flips PUBLISHED -> VERIFIED and bumps the counter
select record_solution_feedback(:'seed1_id', true);
do $$ begin
  assert (select status from solutions where id = current_setting('test.seed1_id')::uuid) = 'VERIFIED', 'D1: accept -> VERIFIED';
  assert (select times_accepted from solutions where id = current_setting('test.seed1_id')::uuid) = 1,  'D1b: times_accepted bumped';
end $$;

-- D2: bob cannot directly tamper with a live solution he does not own
do $$
declare n int;
begin
  update solutions set title = 'tampered' where id = current_setting('test.seed1_id')::uuid;
  get diagnostics n = row_count;
  assert n = 0, 'D2: direct update of a shared live solution by a non-owner affects 0 rows';
end $$;
reset role;

-- ══ E. Cross-company user visibility ════════════════════════════════════════
select set_config('test.current_user_id', :'bob_id', false);
set role authenticated;
do $$ begin
  assert (select count(*) from users) = 2, 'E1: bob sees only company A users (alice + bob)';
  assert     exists (select 1 from users where id = current_setting('test.alice_id')::uuid), 'E1b: bob sees alice';
  assert not exists (select 1 from users where id = current_setting('test.carol_id')::uuid), 'E1c: bob cannot see carol';
end $$;
reset role;

\echo ''
\echo '  =================================================='
\echo '   ALL RLS / RPC ASSERTIONS PASSED'
\echo '  =================================================='
\echo ''
