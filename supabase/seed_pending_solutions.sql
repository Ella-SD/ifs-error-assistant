-- Seed: 4 hand-curated starter solutions, loaded as PENDING_REVIEW so the admin
-- approves each in-app (exercises the review queue + the new library badge).
-- Catalog fields (component/package/lu/version) taken from the real IFS10 catalog
-- so each solution re-links to its error. source = ADMIN (hand-curated).
-- Run once in the Supabase SQL editor.

insert into solutions
  (error_code, lu_name, package_name, component_code, component_name, error_template, ifs_version, title, who_acts, instructions, status, source)
values
-- 1. Finance / GL — accounting period closed for user group
('PERIODCLOSED','PeriodAllocation','PERIOD_ALLOCATION_API','ACCRUL','Accounting Rules',
 'One or more period(s) in the interval are closed for user group :P1.','IFS10',
 'Accounting period is closed for your user group','Finance / GL Administrator',
 jsonb_build_array(
   'Note the user group named in the message — the period is closed specifically for that group.',
   'Check the posting date on your transaction and which accounting period it falls in.',
   'If you can post to a later open period, change the date to one within an open period and retry.',
   'If it must post to the closed period, ask your Finance/GL administrator to reopen it for your user group (General Ledger → period status by user group).',
   'Once reopened, retry the posting.'
 ),'PENDING_REVIEW','ADMIN'),

-- 2. Finance / AP — supplier blocked for payment
('SUPPBLOCKED','LedgerTransaction','LEDGER_TRANSACTION_API','PAYLED','Payment Ledger',
 'Supplier :P1 is blocked for payment.','IFS10',
 'Supplier is blocked for payment','Accounts Payable / Finance',
 jsonb_build_array(
   'Note the supplier ID — payments to this supplier are currently blocked.',
   'This is usually deliberate (a Finance payment hold) — check why before releasing.',
   'Open the supplier record → Payment tab → check the "blocked for payment" / payment-stop setting.',
   'If the hold should lift, have an authorized Finance user remove the payment block.',
   'If it is intentional (dispute, missing documents), resolve that first — do not force the payment.',
   'Once unblocked, retry the payment proposal or run.'
 ),'PENDING_REVIEW','ADMIN'),

-- 3. Procurement — cannot delete a PO line in its current status
('DELETENOTPERMITTED','PurchaseOrderLine','PURCHASE_ORDER_LINE_API','PURCH','Purchasing',
 'Deletion not permitted when status is :P1','IFS10',
 'Can''t delete a purchase order line in its current status','Buyer / Purchasing',
 jsonb_build_array(
   'Open the purchase order and check the line''s status — deletion is blocked in that status.',
   'A PO line can only be deleted while the order is in Planned status.',
   'If it is Confirmed, click Plan to move it back to Planned (only works if the line has no receipts or invoices).',
   'With the order in Planned, select the line and click Delete.',
   'If it cannot be moved back (has receipts, or pending approval), cancel the line instead, or contact your Purchasing admin.'
 ),'PENDING_REVIEW','ADMIN'),

-- 4. Sales / Order — customer credit blocked, order won't release
('NOPICKCUSTCREBLK','CustomerOrder','CUSTOMER_ORDER_API','ORDER','Customer Orders',
 'The customer :P1 is credit blocked. The order cannot be released.','IFS10',
 'Customer is credit blocked — order can''t be released','Order Admin / Credit Control / Finance',
 jsonb_build_array(
   'Note the customer named in the message — they are on credit block, so the order will not release.',
   'This is deliberate credit control — check why before overriding.',
   'Review the customer''s credit status, limit, and outstanding balance (Customer → Credit Information).',
   'If it is a limit issue, the customer pays down their balance, or Finance raises the credit limit.',
   'If the block should lift, have Credit Control / Finance remove it (or approve a one-off exception).',
   'Once cleared or an exception is approved, release the order again.',
   'If it is genuinely over-limit, hold the order until payment clears — do not force it.'
 ),'PENDING_REVIEW','ADMIN');
