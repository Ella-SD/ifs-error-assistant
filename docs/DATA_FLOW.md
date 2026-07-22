# Data flow & third-party processing

Written to capture where user data goes while it's fresh — useful for enterprise
procurement/security reviews as the platform scales past the D&K pilot. Not
published anywhere; internal reference.

## Systems involved

| System | Role | Data it sees |
|---|---|---|
| **GitHub Pages** | Static hosting of `index.html` | none server-side (static files only) |
| **Supabase** (Postgres/Auth) | Accounts, shared solution library, company-private archive, resolution records | account data, error text, solutions, resolutions, billing status |
| **Vercel** (proxy functions) | AI proxy + billing/webhook endpoints | passes through AI requests; never persists them |
| **Anthropic API** | Vision/OCR extraction + Tier-2 web research | **error screenshots** + extracted text (transient, per request) |
| **Stripe** | Payments (subscriptions, PAYG) | billing/customer/payment data |

## The screenshot path (the sensitive one)

1. User uploads an IFS error **screenshot** in the browser → held in memory as base64.
2. On "Analyze," the browser POSTs it to the Vercel proxy (`/api/messages`), which
   forwards it to the **Anthropic API** for vision extraction (reading the error
   text off the image). The proxy verifies the user's session + plan first and
   **does not store** the image or response.
3. Anthropic returns the extracted **error text** (+ screen name, version hint).
4. **The screenshot itself is never persisted** — not by the proxy, not in the
   database. Only the *extracted text fields* are written to `archive_entries`.
5. `archive_entries` is **company-isolated by RLS** (a company can only ever read
   its own rows; not even `platform_admin` can read another company's archive).

**Why this matters:** IFS error screenshots can contain customer names, order
numbers, and financial data. That image transits Anthropic's API for processing
(Anthropic does not train on API inputs by default) but is **not retained** by
this app. Extracted text that *is* retained lives only in the submitting
company's private archive.

## The paid-resolution path (how fix steps are served)

Solution steps are a paid product, so they are **never bulk-loaded into the
browser** and are gated at the database layer, not just the UI:

1. When a user submits an error, a **`resolutions`** row is opened (`start_resolution`
   RPC) recording the match context + the account type — but **not** the steps.
2. The steps reach the user only through one gated path:
   - **Subscribers / platform admin** → `reveal_solution` RPC (free), or
   - **Pay-as-you-go** → the Vercel `/api/billing/unlock` endpoint, which charges
     the saved card once ($4.99, idempotent per resolution) then returns the steps.
3. The **`solutions.instructions`** column has SELECT **revoked from the
   `authenticated` role** (migration 0010), so an end user cannot read steps with a
   hand-crafted query. The gated RPCs run `security definer` (bypass the lock);
   the unlock endpoint uses the service role. Admins manage the library via the
   `admin_solutions_with_steps` RPC.
4. Each resolution stores an **immutable `steps_snapshot`** (the exact steps shown)
   plus the solution version, match confidence, account type, price, and the
   post-reveal **thumbs outcome** — one source of truth for archive, refunds, and
   consultant credit.

`resolutions` is **RLS-scoped to the submitter and their company** (`user_id =
auth.uid() or company_id = auth_company_id()`); as with the archive, there is no
`platform_admin` escape hatch on this row-level error data.

## Where each data type lives

- **Error screenshots** — transient only (browser → Anthropic for OCR); never stored.
- **Extracted error text / archive** — `archive_entries`, company-private (RLS).
- **Resolutions** — `resolutions`, scoped to the submitter + their company (RLS).
  Holds error text/screen/activity (same sensitivity as the archive) + an immutable
  snapshot of the steps served + the billing/outcome record for that resolution.
- **Solutions (fixes)** — shared `solutions` library, platform-wide (the moat). No
  company data; IFS error codes are universal Oracle strings. The `instructions`
  column is read-locked for end users (served only via the gated paths above).
- **Usage / consultant-credit signal** — per-solution counters on `solutions`
  (`times_served`, `times_accepted`, `times_rejected`); counted per SOLUTION, never
  by company. (The old per-company `solution_acceptances` table was removed in 0008.)
- **Accounts** — Supabase Auth (`auth.users`) + `public.users`/`companies`.
- **Billing** — Stripe (customer/subscription + PAYG PaymentIntents) + status
  columns in Supabase, written only by the Stripe webhook / unlock endpoint
  (service role). Editable price lives in `app_config` (`payg_price_cents`).

## Retention

- Archive: retained per company until the company clears it (self-service).
- Resolutions: retained (the immutable record backing refunds + consultant credit).
- Solutions: permanent (shared knowledge base).
- Screenshots: not retained.

## Open items to formalize before enterprise sale

- A written data-processing statement covering the Anthropic OCR hop.
- Consider an optional client-side redaction step for screenshots.
- Confirm Anthropic API data-retention terms in the customer-facing doc.
