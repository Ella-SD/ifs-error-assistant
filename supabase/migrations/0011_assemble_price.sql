-- ============================================================================
-- Separate price knob for AI-assembled fixes.
--
-- Per the canonical scope (Parts 5.3 / 13.2): the no-match AI-Assemble result is
-- a paid resolution ($4.99), but priced from its OWN config value so it can be
-- tuned independently of the main resolution price later (AI-assemble is the most
-- expensive path to produce — live web research + LLM — so price may diverge).
--
-- Same default as payg_price_cents for now; the unlock endpoint picks which key to
-- charge by the solution's status (a live/curated match → payg_price_cents; an
-- unreviewed assembled fix, i.e. non-live status → assemble_price).
-- ============================================================================

insert into app_config(key, value) values ('assemble_price', '499')
  on conflict (key) do nothing;
