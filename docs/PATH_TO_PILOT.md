# Path to pilot launch — D&K

**Current state (2026-07-23):** the full product loop is built and verified end-to-end —
paid resolution ($4.99 PAYG + $49/$299 subscriptions, gated steps), AI-assemble,
thumbs → escalation → refund, "My fixes", and the **lean marketplace** (consultant
onboarding → job → accept → submit → deliver → credit → cash-out). Security-audited.
**Stripe is in TEST mode.** The solution library has **10 sample solutions** only.
This is the checklist from here to real D&K users. (Supersedes GO_LIVE_CHECKLIST.md.)

Legend: **[Ella]** business/dashboard/decisions · **[Code]** app/infra · **[Verify]** confirm.

---

## 1. Business foundation — the gating prerequisite [Ella]
- [ ] Register the **legal entity** (name / type / jurisdiction).
- [ ] Register a **domain** + a **contact/support email** on it.
- [x] Stripe **business profile** completed (via Ella's other business).

## 2. Solution content — so users actually find fixes
Only 10 samples exist today; real users need coverage.
- [ ] **Decide (with Chat):** the full **catalog → Postgres move + ~18K shell-solutions batch** (one per error), **or** a lighter pilot start — seed a focused set of real solutions for D&K's most common errors and let AI-assemble + consultants fill the rest over time.
- [ ] Get *some* real fix coverage beyond the 10 samples before real users hit it.

## 3. Email deliverability [Ella + Code]
- [ ] **Custom SMTP** (provider + domain verify + Supabase → Auth → Emails → SMTP). [Ella]
- [ ] Delivery test to a real inbox. [Verify]
- [ ] Turn **email confirmation ON** (only after SMTP verified). [Ella]

## 4. Legal [Code + Ella]
- [ ] Fill the `legal.html` placeholders — entity name + contact email. [Code, once known]
- [ ] **Legal review** of the ToS/privacy draft. [Ella / counsel]

## 5. Stripe: test → LIVE [Ella + Code]
- [ ] Create the two **LIVE** subscription Products/Prices with lookup keys `ifs_personal_monthly` / `ifs_company_monthly`. [Ella]
- [ ] Create a **LIVE webhook** → `…/api/stripe-webhook`; copy the signing secret. [Ella]
- [ ] Set Vercel **Production** env: `STRIPE_SECRET_KEY` (live), `STRIPE_WEBHOOK_SECRET` (live). [Ella]
- [ ] Flip the escalation Stripe dashboard link `/test/` → live in index.html + redeploy the proxy. [Code]
- [ ] *(Optional)* move the app to the **custom domain** — coordinated pass: proxy CORS `APP_ORIGIN`, Supabase Auth Site URL, Stripe success/cancel URLs. [Code]

## 6. Consultant supply [Ella]
- [x] Staffing confirmed (D&K analyst + a couple of hired IFS pros).
- [ ] Have the real consultants **apply** in the app (💼 Consultant → pick modules) and **approve** them (🛠 Marketplace).

## 7. Final pre-launch sweep [Ella + Code]
- [ ] Delete the **test accounts/companies** (keep one platform_admin). [Ella]
- [ ] **Full live smoke test** on the real domain: subscriber + PAYG resolution, one real escalation → consultant → deliver → cash-out. [Verify]
- [ ] Point the first **D&K users** at the app. [Ella]

---

## Deferred beyond the pilot (intentional — "keep it simple")
- Track B (consultant price negotiation + delta payment)
- Automated email notifications + scheduled timers (7-day window) — manual for now
- Stripe **Connect** payouts — manual credit-ledger cash-out for now
- **IFS Cloud catalog** + version auto-detect (for the broader "all IFS customers" public launch)
- Part 12 open decisions (anonymous entry, trial/freemium, low-confidence pricing) — revisit on real usage data
