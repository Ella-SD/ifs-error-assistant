# Marketplace v1 — phased build plan

Per the canonical scope Part 13.5: build the full consultant marketplace now, as a
core feature of the public launch (superseding the earlier "defer until validated"
call). This is the largest single build on the roadmap — larger than the entire
paid-resolution rework already shipped.

## What's reused vs. net-new

**Reused (already built):** the resolution state machine (0009), the review queue
(DRAFT→PENDING_REVIEW→PUBLISHED/REJECTED), module tagging (catalog `COMPONENT_NAME`),
the `times_accepted` reputation signal, the pay-to-unlock/charge pattern, and the
manual escalation flow (becomes the admin fallback + the model for refund logic).

**Net-new:** `consultant` capability + profiles, a marketplace **jobs / claim &
negotiation state machine**, a **notification pipeline**, **scheduled timers**, and
**Stripe Connect** (Express onboarding, KYC, transfers, monthly payouts).

---

## Phase 0 — Foundations + two decisions to settle first

**0a. Framework decision (blocking — shapes everything after).**
The app is a single ~2,900-line `index.html` (vanilla JS, no build step, GitHub
Pages). The scope doc itself flags framework migration as due "before marketplace
UI work." Marketplace v1 roughly doubles the UI surface (consultant onboarding,
queue/dashboard, claim + price-proposal flows, notifications, Connect onboarding
redirects, admin marketplace views).
- **Recommendation:** migrate to a build-tooled SPA (Vite + a light framework) or
  Next.js on Vercel **before** the marketplace UI, and port the existing app first.
  Building this much new UI in the single-file approach will be slow and brittle.
- **Tradeoff:** the migration is itself real effort + a full re-test of everything
  shipped. Alternative is to keep building in the single file and migrate later
  (cheaper now, more to migrate later).
- **Decision needed from Ella/Chat:** migrate now (recommended) vs. build-in-place.

**0b. Data model (once 0a is settled):**
- **Consultant capability, orthogonal to company role.** A person can be a
  `company_member` *and* a consultant (Part 10.2), so this is NOT a new value on the
  single `users.role` enum. Add `consultant_profiles(user_id, modules text[], tier,
  stripe_connect_account_id, onboarding_status, active)` + an `is_consultant` flag.
- **`marketplace_jobs`** table + state enum:
  `open → claimed → price_proposed → awaiting_user_payment → in_progress →
   submitted_for_review → delivered | rejected | refunded | reopened`.
  Links to the originating `resolution_id`; carries `module`, `consultant_id`,
  `proposed_price_cents`, `delta_payment_intent`, `claimed_at`, `deadline_at`.
- **`notifications`** table (recipient, type, payload, read_at).
- **Config** (app_config, editable): tier thresholds (Bronze/Silver/Gold), split
  percentages (30/70 → 25/75 → 20/80), response-window days.
- **Entry points into the queue:** define exactly when a job is created — (a) a
  genuine no-match where the user opts for a consultant, and (b) a rejected fix
  (the existing 👎 escalation). The manual escalation states map onto these.

**0c. Consultant onboarding (basic):** apply-to-be-a-consultant + pick module
specializations + admin approval. (Stripe Connect onboarding lands in Phase 3.)

## Phase 1 — Claim + two-track pricing (the core marketplace loop)
- **Consultant queue view:** open jobs filtered to the consultant's module(s).
- **Claim** a job (guard: one active claim per consultant; claimed jobs leave the
  open queue).
- **Track A (default):** accept at $4.99, start immediately.
- **Track B:** propose a higher price → the end user must **accept + pay the delta
  before work starts** (reuses the pay-to-unlock pattern) — no unpaid speculative work.
- **Do work → submit fix → existing review queue** → on approval, delivered to the
  user (via "My fixes" + a notification).
- **Refund hooks:** decline/no-response → refund the $4.99; paid-but-failed or
  rejected-in-review → refund the full amount (base + delta).

## Phase 2 — Notifications + scheduled timers
- **Notification pipeline:** in-app notifications table + **email** (depends on the
  go-live SMTP being configured — consultants won't live in the app). Events: job
  queued (to module-matched consultants), claimed, price-proposed (to user),
  mid-window reminder, in-progress, submitted-for-review, delivered, refunded.
- **Scheduler:** `pg_cron` in Supabase (simplest for DB-driven timers) drives the
  7-day response window, the mid-window reminder, and no-response → decline →
  reopen + refund. No manual admin polling.

## Phase 3 — Stripe Connect payouts
- **Consultant onboarding:** Stripe Connect **Express** accounts via Account Links
  (KYC/tax collected by Stripe).
- **Money flow:** user pays base + delta to the platform → on **verified delivery**
  (review passed), compute the tiered split and create a **transfer** to the
  consultant's connected account (held until review passes) → **monthly payout** via
  Connect's native scheduling.
- **Refunds** coordinated across the platform charge and any consultant transfer.

## Cross-cutting (not code, but blockers before this goes public)
- **Consultant agreement / ToS** (Part 12) — paying people for advice on live ERP
  data needs a real agreement (liability, conduct, dispute handling). Hard blocker
  before consultants transact.
- **Money-movement/compliance** — running payouts makes the platform a marketplace;
  Stripe Connect handles much of the tax/KYC, but the legal posture needs review.
- **Reputation → split** wiring: tier (from `times_accepted`) sets the transfer %.

## Sequencing / risk
Phases are roughly independent and land value incrementally: Phase 1 gives a working
claim+price loop (payouts manual in the interim, like today), Phase 2 removes manual
timer/notification work, Phase 3 automates payouts. **Phase 3 (Connect) is the
heaviest and carries the most compliance weight** — worth starting its onboarding/KYC
plumbing early even while Phases 1–2 proceed.
