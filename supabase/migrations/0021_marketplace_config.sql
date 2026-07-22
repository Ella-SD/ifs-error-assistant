-- ============================================================================
-- Marketplace v1 · Phase 0 — editable config (thresholds & splits).
--
-- All tunable numbers live in app_config (platform_admin-editable) rather than
-- hardcoded, consistent with every other price/threshold in this build (scope 5.4).
-- ============================================================================

insert into app_config(key, value) values
  ('marketplace_sla_days',    '7'),    -- Track B response window (days)
  ('trackb_cap_multiplier',   '5'),    -- max Track B proposed price = 5x base $4.99 (scope 13.6 #3)
  ('tier_split_bronze',       '70'),   -- consultant % of the fee (platform keeps the remainder)
  ('tier_split_silver',       '75'),
  ('tier_split_gold',         '80'),
  ('tier_threshold_silver',   '25'),   -- verified accepted-uses to reach Silver
  ('tier_threshold_gold',     '100'),  -- ... to reach Gold
  ('consultant_cashout_min_cents', '5000')  -- min credit balance before a manual cash-out
on conflict (key) do nothing;
