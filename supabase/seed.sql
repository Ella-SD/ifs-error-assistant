-- ============================================================================
-- Phase 2 · Step 1 — Seed data
-- The 10 founding solutions, ported verbatim from the Phase 1 index.html seed
-- array into the shared `solutions` table. This is the platform's starting
-- dataset (the moat's first entries).
--
-- Idempotent: skips entirely if `solutions` already has rows, so re-running
-- against a populated database is a no-op. Apply AFTER the three migrations.
--
-- Fidelity notes:
--   * seed1 is PUBLISHED with 4 instructions; published_at stamped now().
--   * seed2..seed10 are NO_INSTRUCTION (catalog entries without a fix yet),
--     instructions = []. This matches the Phase 1 data exactly.
--   * contributed_by_user_id is null (platform-authored, pre-accounts).
--   * jsonb_build_array() is used for instruction text so no manual JSON
--     escaping is needed.
-- ============================================================================

do $$
begin
  if exists (select 1 from solutions) then
    raise notice 'solutions table already populated — skipping seed';
    return;
  end if;

  insert into solutions
    (error_code, lu_name, package_name, component_code, component_name,
     error_template, ifs_version, title, who_acts, status, source, instructions, published_at)
  values
    ('DELETENOTPERMITTED', 'PurchaseOrderLinePart', 'PURCHASE_ORDER_LINE_PART_API', 'PURCH', 'Procurement',
     'Deletion not permitted when status is :P1', 'IFS10',
     'Deletion not permitted when status is Confirmed', 'Buyer or Procurement Admin',
     'PUBLISHED', 'ADMIN',
     jsonb_build_array(
       'Open the Purchase Order and check the current status — it must be Confirmed.',
       'To delete a PO line, first change the PO status back to Planned by clicking the Plan button.',
       'Once the status is Planned, select the line you want to delete and click Delete.',
       'If you cannot change the status, contact your Procurement Admin — the PO may be locked for approval.'
     ),
     now());

  insert into solutions
    (error_code, lu_name, package_name, component_code, component_name,
     error_template, ifs_version, title, who_acts, status, source, instructions)
  values
    ('SAMEORDEREXIST', 'CustomerOrderFlow', 'CUSTOMER_ORDER_FLOW_API', 'ORDER', 'Customer Orders',
     'The customer order :P1 has already been processed by another user and added to the background job :P2.', 'IFS10',
     'Customer order already processed by another user', 'Buyer or Production Control',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('WRONGCOMPANY', 'AbcFrequencyLifecycle', 'ABC_FREQUENCY_LIFECYCLE_API', 'INVENT', 'Inventory',
     'Site :P1 does not belong to company :P2.', 'IFS10',
     'Site does not belong to company', 'IT Admin or IFS System Administrator',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('ACCYEARNOTOPEN', 'AccountingPeriod', 'ACCOUNTING_PERIOD_API', 'ACCRUL', 'Accounting Rules',
     'Accounting year is not open. Therefore Accounting period(s) cannot be created.', 'IFS10',
     'Accounting year is not open', 'Finance Team',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('PERIODCLOSED', 'PeriodAllocation', 'PERIOD_ALLOCATION_API', 'ACCRUL', 'Accounting Rules',
     'One or more period(s) in the interval are closed for user group :P1.', 'IFS10',
     'Accounting period is closed', 'Finance Team',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('NODIRECTINSERT', 'AccountingAttribute', 'ACCOUNTING_ATTRIBUTE_API', 'ACCRUL', 'Accounting Rules',
     'A record cannot be entered/modified as :P1 window has been set up for copying data only from source company in Basic Data Synchronization window.', 'IFS10',
     'Record cannot be entered — Basic Data Synchronization restriction', 'Finance Team or IT Admin',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('NODIRECTREMOVE', 'AccountingAttribute', 'ACCOUNTING_ATTRIBUTE_API', 'ACCRUL', 'Accounting Rules',
     'A record cannot be removed as :P1 window has been set up for copying data only from source company in Basic Data Synchronization window.', 'IFS10',
     'Record cannot be removed — Basic Data Synchronization restriction', 'Finance Team or IT Admin',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('WRONGABCSUM', 'AbcClass', 'ABC_CLASS_API', 'INVENT', 'Inventory',
     'The sum of the percentages must be 100.', 'IFS10',
     'ABC class percentages do not add up to 100', 'Inventory Planner',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('NOVALYP', 'PeriodAllocRuleLine', 'PERIOD_ALLOC_RULE_LINE_API', 'ACCRUL', 'Accounting Rules',
     'Not a valid Accounting Year / Period', 'IFS10',
     'Invalid accounting year or period entered', 'Finance Team',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb),

    ('USERGRPDATEERROR', 'AccountingPeriod', 'ACCOUNTING_PERIOD_API', 'ACCRUL', 'Accounting Rules',
     'User Group :P1 is not valid for Voucher Date :P2', 'IFS10',
     'User group not valid for the voucher date', 'Finance Team',
     'NO_INSTRUCTION', 'ADMIN', '[]'::jsonb);

  raise notice 'seeded % founding solutions', (select count(*) from solutions);
end $$;
