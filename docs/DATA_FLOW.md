# Data flow & third-party processing

Written to capture where user data goes while it's fresh — useful for enterprise
procurement/security reviews as the platform scales past the D&K pilot. Not
published anywhere; internal reference.

## Systems involved

| System | Role | Data it sees |
|---|---|---|
| **GitHub Pages** | Static hosting of `index.html` | none server-side (static files only) |
| **Supabase** (Postgres/Auth) | Accounts, shared solution library, company-private archive | account data, error text, solutions, billing status |
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

## Where each data type lives

- **Error screenshots** — transient only (browser → Anthropic for OCR); never stored.
- **Extracted error text / archive** — `archive_entries`, company-private (RLS).
- **Solutions (fixes)** — shared `solutions` library, platform-wide (the moat). No
  company data; IFS error codes are universal Oracle strings.
- **Cross-company reuse signal** — `solution_acceptances` (which company accepted
  which fix); platform-aggregate only, admin-visible for the moat dashboard.
- **Accounts** — Supabase Auth (`auth.users`) + `public.users`/`companies`.
- **Billing** — Stripe (customer/subscription) + status columns in Supabase,
  written only by the Stripe webhook (service role).

## Retention

- Archive: retained per company until the company clears it (self-service).
- Solutions: permanent (shared knowledge base).
- Screenshots: not retained.

## Open items to formalize before enterprise sale

- A written data-processing statement covering the Anthropic OCR hop.
- Consider an optional client-side redaction step for screenshots.
- Confirm Anthropic API data-retention terms in the customer-facing doc.
