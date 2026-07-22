# Go-live checklist — D&K pilot (IFS 10)

Plan of record for taking the pilot live with the first real customer. Direction
(2026-07-22, confirmed with Chat): go live now on IFS 10; the IFS Cloud catalog +
Postgres move come later, timed to the public-marketing push. The Part 12 batch
(anonymous entry, preview TTL, trial/freemium, low-confidence pricing) is on hold
until there's real usage data.

Legend: **[Ella]** dashboard/keys/decisions · **[Code]** app/infra changes · **[Verify]** confirm it works.

---

## 0. Before flipping anything — exercise the refund path (TEST mode)
The one flow never run against a real charge. Do it in **test** mode first.
- [ ] **[Ella+Code]** As `paygtest`, unlock a fix ($4.99 test charge) → 👎 → **Request a review**. Confirm the promise reads **"verified fix or a full refund"** (refundable wording).
- [ ] **[Verify]** In the admin **Escalations** tab: the case shows **"Paid $4.99"** + an **open-in-Stripe** link; click it and confirm it lands on the right test PaymentIntent.
- [ ] **[Ella]** Refund that PaymentIntent in Stripe (test) → back in the app click **Mark refunded** → confirm it moves to *Refunded*.
- [ ] Fix anything that surfaces here before go-live.

## 1. Custom SMTP (signup/confirmation email reliability)
Supabase's built-in mailer is rate-limited + spam-prone; real signups need custom SMTP.
- [ ] **[Ella]** Create a sender on a provider (Resend / SendGrid / Postmark), verify the sending domain (SPF/DKIM).
- [ ] **[Ella]** Supabase → **Authentication → Emails → SMTP** → enter host/port/user/pass + from-address.
- [ ] **[Verify]** Sign up a throwaway to a real inbox → confirmation email arrives (not spam) and the link lands on the app.

## 2. Terms of Service + Privacy Policy page
- [ ] **[Code]** Draft a starter ToS + privacy policy (grounded in `docs/DATA_FLOW.md`: screenshots not stored, error text company-private, Anthropic OCR hop, Stripe billing) and wire a link on the auth screen + footer. **Marked as a starting draft — needs legal review.**
- [ ] **[Ella]** Review / have counsel review before public marketing (not a hard pilot blocker, but should exist before the first real customer).

## 3. Stripe: test → LIVE
Card capture is Stripe-hosted (no client key), so this is dashboard + env-var work.
- [ ] **[Ella]** In Stripe **LIVE** mode, create the two subscription Products/Prices with the **exact lookup keys** the code resolves at runtime: `ifs_personal_monthly` ($49/mo) and `ifs_company_monthly` ($299/mo). (PAYG needs no Price object — it's a direct PaymentIntent from `app_config.payg_price_cents`.)
- [ ] **[Ella]** Create a **LIVE webhook endpoint** → URL = `https://ifs-error-assistant-proxy.vercel.app/api/stripe-webhook` → subscribe to the billing events (checkout.session.completed, customer.subscription.created/updated/deleted, invoice.*). Copy the **live signing secret**.
- [ ] **[Ella]** Vercel (proxy project) → set **Production** env vars: `STRIPE_SECRET_KEY` = live `sk_live_…`, `STRIPE_WEBHOOK_SECRET` = live `whsec_…`. (`ANTHROPIC_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY` unchanged.)
- [ ] **[Code]** Flip the admin escalation Stripe dashboard link from `/test/payments/` to `/payments/` (index.html) and push.
- [ ] **[Code]** Redeploy the proxy (`vercel --prod`) so the new env vars take effect. *(needs go-ahead)*
- [ ] **[Verify]** One real subscription checkout (small, refundable) + one real $4.99 PAYG charge on the live site → confirm access is granted and the webhook lands.

## 4. Escalation queue staffing
- [x] **[Ella]** Confirmed — covered directly, plus a couple of hired IFS professionals. (The "a specialist will review" promise is real.)

## 5. Final pre-launch sweep
- [ ] **[Verify]** Full happy path on the live domain as a real subscriber and a real PAYG user (screenshot → reveal, search → reveal, thumbs).
- [ ] **[Verify]** No test accounts/companies remain except intended ones.
- [ ] **[Ella]** Point the first D&K user(s) at `https://ella-sd.github.io/ifs-error-assistant/`.

---

**Deferred (post-pilot, pre-public-marketing):** IFS Cloud catalog + Postgres move + screenshot version auto-detect; Part 12 batch decisions after a few days of real usage data.
