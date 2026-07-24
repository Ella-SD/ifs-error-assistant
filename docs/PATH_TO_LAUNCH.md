# Path to public launch

**This is a general commercial product for all IFS customers, launching publicly.**
There is no anchor customer and no pilot company — the launch is public from the start.

**Current state (2026-07-23):** the full product loop is built and verified end-to-end —
paid resolution ($4.99 PAYG + $49/$299 subscriptions, gated steps), AI-assemble,
thumbs → escalation → refund, "My fixes", and the **lean marketplace** (consultant
onboarding → job → accept → submit → deliver → credit → cash-out). Security-audited.
**Stripe is in TEST mode.** The solution library has **10 sample solutions** only.
Launch scope is confirmed as **flat $4.99 + lean marketplace** (Track B + Stripe Connect
deferred). This is the checklist from here to a public launch.

Legend: **[Ella]** business/dashboard/decisions · **[Code]** app/infra · **[Verify]** confirm.

---

## 1. Business foundation — the gating prerequisite [Ella]
- [ ] Register the **legal entity** (name / type / jurisdiction).
- [ ] Register a **domain** + a **contact/support email** on it.
- [x] Stripe **business profile** completed.

## 2. Solution content — so users actually find fixes
Only 10 samples exist today; a public audience needs real coverage.
**Decision (2026-07-23, confirmed with Chat): lighter hand-curated seed — quality over quantity.**
- [ ] Hand-curate a real solution set for the **most common / foundational IFS errors** before public users arrive.
- [ ] Let **AI-assemble + the marketplace** fill coverage gaps organically from real usage — that is exactly what those two features exist to do.
- [ ] **Deferred to post-launch** (timed to real usage data, not pre-launch guesswork): the full **catalog → Postgres migration + ~18K shell-solution batch**, and the **IFS Cloud catalog**. These remain the right eventual investment, just not now.

## 3. Email deliverability [Ella + Code]
- [ ] **Custom SMTP** (provider + domain verify + Supabase → Auth → Emails → SMTP). [Ella]
- [ ] Delivery test to a real inbox. [Verify]
- [ ] Turn **email confirmation ON** (only after SMTP verified). [Ella]

## 4. Legal [Code + Ella]
- [ ] Fill the `legal.html` placeholders — entity name + contact email. [Code, once known]
- [ ] **Legal review** of the ToS/privacy draft. [Ella / counsel]
- [ ] **Consultant agreement** — a real agreement before any consultant transacts (paying people for advice on live ERP data). [Ella / counsel]
- [ ] Public-audience **privacy/GDPR** policy (international signups). [Ella / counsel]

## 5. Stripe: test → LIVE [Ella + Code]
- [ ] Create the two **LIVE** subscription Products/Prices with lookup keys `ifs_personal_monthly` / `ifs_company_monthly`. [Ella]
- [ ] Create a **LIVE webhook** → `…/api/stripe-webhook`; copy the signing secret. [Ella]
- [ ] Set Vercel **Production** env: `STRIPE_SECRET_KEY` (live), `STRIPE_WEBHOOK_SECRET` (live). [Ella]
- [ ] Flip the escalation Stripe dashboard link `/test/` → live in index.html + redeploy the proxy. [Code]
- [ ] Move the app to the **custom domain** — coordinated pass: proxy CORS `APP_ORIGIN`, Supabase Auth Site URL, Stripe success/cancel URLs. [Code]

## 6. Consultant supply [Ella]
- [x] Staffing approach: manually-recruited IFS professionals to seed the supply side.
- [ ] Have consultants **apply** in the app (💼 Consultant → pick modules) and **approve** them (🛠 Marketplace).

## 7. Final pre-launch sweep [Ella + Code]
- [ ] Delete the **test accounts/companies** (keep one platform_admin). [Ella]
- [ ] **Full live smoke test** on the real domain: subscriber + PAYG resolution, one real escalation → consultant → deliver → cash-out. [Verify]
- [ ] **Go live** publicly (marketing on LinkedIn / YouTube / IFS forums per the plan). [Ella]

---

## Deferred beyond launch (intentional — "keep it simple")
- Track B (consultant price negotiation + delta payment)
- Automated email notifications + scheduled timers (7-day window) — manual for now
- Stripe **Connect** payouts — manual credit-ledger cash-out for now
- **IFS Cloud catalog** + version auto-detect (broadens coverage to Cloud customers)
- Part 12 open decisions (anonymous entry, trial/freemium, low-confidence pricing) — revisit on real usage data
