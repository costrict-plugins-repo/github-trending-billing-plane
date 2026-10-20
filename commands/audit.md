---
description: Audit your codebase for Stripe billing violations, security risks, and missing edge case handling. Scans for hardcoded prices, exposed keys, missing webhook coverage, lifecycle gaps, usage billing issues, and entitlement vulnerabilities.
argument-hint: [path-to-scan]
context: fork
---

# /billingplane:audit

## Purpose
Deep-scan an existing codebase for billing violations against BillingPlane guardrails. Read-only operation. Produces a severity-ranked audit report with exact file locations and fixes.

## Instructions

1. **Determine scan scope**: If `$ARGUMENTS` is provided, scan that path. Otherwise, scan the project root.

2. **Detect stack first**: Check package.json, requirements.txt, go.mod to understand framework, ORM, and existing Stripe SDK version.

3. **Scan for ALL violation categories below.**

---

### CATEGORY 1: Core Security (CRITICAL)

**1a. Hardcoded Prices (Rule 1)**
- Grep: `amount.*=.*\d{3,}`, `unit_amount`, `price_1_` (hardcoded Stripe Price IDs)
- Flag: inline amount values in Stripe API calls not sourced from env vars or config maps
- NOT a violation: config files referencing `process.env.STRIPE_PRICE_*`

**1b. Exposed Stripe Secret Keys (Rule 2)**
- Grep: `sk_live_`, `sk_test_` in client-accessible files (`src/`, `app/`, `pages/`, `public/`, `components/`)
- Check `.gitignore` includes `.env` files
- Flag: secret keys in client bundles or serialized server component props

**1c. Webhook Signature Missing (Rule 7)**
- Find webhook endpoints (routes containing `webhook` or `stripe` in API paths)
- Verify `constructEvent` / `constructEventAsync` called with raw body + stripe-signature header
- Flag: `JSON.parse(req.body)` BEFORE signature verification
- Flag: `express.json()` applied globally without raw body exception for webhook route
- Flag: Next.js App Router webhook using `req.json()` instead of `req.text()` for raw body

---

### CATEGORY 2: State Management (CRITICAL)

**2a. Billing State Outside Webhooks (Rule 4)**
- Search for subscription/plan status writes in non-webhook handlers
- Flag: checkout success handlers that activate subscriptions based on redirect params
- Flag: API routes that change entitlements based on Stripe API response rather than webhook

**2b. Success Page Trusts Redirect (Rule 5)**
- Flag: success URL handlers that unlock features or write DB based on `session_id` query param
- Correct: success page polls server endpoint that checks webhook-confirmed state

**2c. Client-Side Entitlements (Rule 6)**
- Flag: `localStorage`/`sessionStorage`/cookie-based plan checks
- Flag: `if (user.plan === 'pro')` in client code without server entitlement call
- Flag: JWT-based feature flags not refreshed from server after billing changes

---

### CATEGORY 3: Webhook Robustness (HIGH)

**3a. Idempotency (Rule 8)**
- Check webhook handlers deduplicate by `event.id` before processing
- Best: Redis `SET NX PX` (atomic check-and-set with TTL, fail-open on Redis error)
- Acceptable: DB unique constraint on event_id with transaction wrapping
- Flag: no dedup at all, or DB dedup without proper conflict handling

**3b. Webhook Event Coverage**
- List ALL handled event types. Flag missing events:

  **Tier 1 (core billing):** `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`

  **Tier 2 (production reliability):** `invoice.created` (usage-in-arrear line items), `invoice.finalized`, `invoice.payment_failed`

  **Tier 3 (advanced lifecycle):** `customer.subscription.trial_will_end`, `subscription_schedule.canceled`, `invoice.updated`, `customer.discount.deleted`

**3c. Webhook Response Pattern**
- Must return 200 quickly then process async (or process fast and return 200)
- Flag: heavy DB work before responding
- Flag: returning non-200 on processing errors (causes Stripe retries = duplicate processing)

---

### CATEGORY 4: Subscription Lifecycle (HIGH)

**4a. Missing `previous_attributes` Inspection**
- `customer.subscription.updated` handler MUST inspect `event.data.previous_attributes` to detect:
  - New cancellation: `cancel_at_period_end` changed false→true, or `cancel_at` went from null→set
  - Reactivation: `cancel_at_period_end` changed true→false (un-cancel)
  - Past due transition: `status` changed to `past_due`
  - Plan change via schedule: `items` changed while schedule exists
- Flag: handler that treats every subscription.updated event identically

**4b. Cancellation Variants**
- Must differentiate: `cancel_at_period_end` (end of cycle) vs `cancel_at` (specific date) vs immediate deletion
- Flag: only one cancellation path implemented

**4c. Reactivation (Un-cancel)**
- When user reverses cancellation, system must: clear cancel state, remove scheduled fallback products
- Flag: no reactivation path in subscription.updated handler

**4d. Past Due Handling**
- Check: grace period logic, status transition detection (`active`→`past_due`), dunning configuration
- Flag: `past_due` subscriptions granting full access indefinitely

**4e. Default Product Fallback**
- On paid plan cancellation (end-of-cycle), user should fall back to free/default plan at period end
- Flag: cancellation that just deletes without scheduling a fallback

**4f. Trial Lifecycle**
- Check: `trial_ends_at` stored, trial→paid transition in webhooks, trial-just-ended detection (skip billing trial usage), `trial_will_end` event handler
- Flag: trial configured in Stripe with no trial-specific code

---

### CATEGORY 5: Usage & Entitlement Billing (HIGH)

**5a. Usage Tracking Architecture**
- If billing has usage components, check for: tracking endpoint, atomic balance deduction (Redis Lua or DB transaction), overage behavior (cap/reject/allow+bill)
- Flag: `UPDATE SET balance = balance - 1` without transaction isolation

**5b. Arrear Billing on invoice.created**
- Usage-in-arrear models: `invoice.created` must add usage line items via `stripe.invoiceItems.create()` BEFORE invoice finalizes
- Flag: usage pricing without `invoice.created` handler

**5c. Final Invoice on Subscription Deletion**
- `customer.subscription.deleted` must create final arrear invoice for outstanding usage
- Flag: subscription.deleted handler ignoring remaining usage

**5d. Credit System Safeguards**
- Atomic deduction, overflow/underflow protection, rollover logic, insufficient balance handling
- Flag: credit deduction without atomicity or negative balance checks

**5e. Entitlement Reset Mechanism**
- Periodic usage limits need: cron or lazy-reset, `next_reset_at` tracking, reset aligned to billing cycle anchor
- Flag: billing-cycle usage limits with no reset mechanism

---

### CATEGORY 6: Concurrency & Caching (MEDIUM)

**6a. Subscription Mutation Locks**
- During plan changes, concurrent webhooks can conflict
- Flag: no locking during subscription mutations (upgrade + webhook arrive simultaneously)

**6b. Cache Invalidation After Webhooks**
- If billing state is cached (Redis, in-memory), webhooks must invalidate after processing
- Flag: cached billing state without webhook-triggered invalidation

---

### CATEGORY 7: Money Safety (MEDIUM)

**7a. Client-Side Money Math (Rule 10)**
- Flag: proration, tax, or discount calculations outside Stripe
- Flag: `toFixed(2)` on currency amounts (floating point)

**7b. Decimal Handling**
- Server-side money computation must use integer cents or Decimal.js
- Flag: floating point arithmetic on currency values

---

### CATEGORY 8: Feature Gating & Entitlement Engine (HIGH) — NEW

**8a. Client-Side Feature Gating**
- Grep: `user.plan`, `plan === `, `subscription.plan`, `isPro`, `isEnterprise` in client code
- Flag: Plan name checks instead of entitlement checks
- Flag: Feature gating logic without server-side enforcement

**8b. Check Endpoint Missing Credit System Fallback**
- Look at the check/entitlement function: does it ONLY check direct feature balance?
- Flag: No cascade from direct feature → credit system pools
- Reference: `feature-gating.md` Section 2, Step 4

**8c. Non-Atomic Check + Track**
- Pattern: separate `check()` then `track()` calls for countable resources
- Flag: TOCTOU race condition — balance can change between check and track
- Fix: Atomic check+track (send_event) or database transaction wrapping both

**8d. Missing Default Deny on Error**
- Look at catch blocks in check endpoint
- Flag: `catch (error) { return { allowed: true } }` — NEVER allow on error
- Flag: Unhandled exceptions that return 500 instead of `{ allowed: false }`

**8e. No Lazy Reset**
- Check if entitlement check evaluates `next_reset_at` before balance comparison
- Flag: Relies only on cron for resets — stale balances if cron is late

**8f. Missing Entity Scope in Check/Track**
- If app has workspaces/teams/seats: does check() accept entity_id?
- Flag: Customer-level check when entity-level is required

**8g. Missing Upgrade Preview**
- When check returns `allowed: false`, does it suggest what to buy?
- Flag: Generic "limit reached" with no actionable upgrade path

**8h. Floating-Point Balance Arithmetic**
- Grep: `balance - `, `balance + `, `remaining >= ` without Decimal.js
- Flag: Floating-point comparison for balance checks (0.1 + 0.2 ≠ 0.3)

**After audit, run test validation:**
Reference `commands/feature-gating-requirements.md` Section C checklist to validate all 56 test cases against your implementation.

---

4. **Check Environment Variables**: Flag missing `STRIPE_WEBHOOK_SECRET`, secret keys in committed files.

5. **Generate Report**:

```
## BillingPlane Audit Report v2

### Summary
- Critical: X violations
- High: Y violations
- Medium: Z violations
- Webhook Coverage: X/12 events handled
- Lifecycle Coverage: X/13 scenarios covered

### CRITICAL Violations
1. [Category/Rule] Description — `file:line`
   Impact: ...
   Fix: ...

### HIGH Violations
...

### Webhook Event Coverage
| Event | Status | Handler Location |
|-------|--------|-----------------|
| checkout.session.completed | ✅/❌ | `path:line` |
| customer.subscription.created | ✅/❌ | |
| customer.subscription.updated | ✅/❌ | |
| customer.subscription.deleted | ✅/❌ | |
| invoice.paid | ✅/❌ | |
| invoice.created | ✅/❌ | |
| invoice.finalized | ✅/❌ | |
| invoice.payment_failed | ✅/❌ | |
| customer.subscription.trial_will_end | ✅/❌ | |
| subscription_schedule.canceled | ✅/❌ | |

### Lifecycle Coverage
| Scenario | Covered |
|----------|---------|
| New subscription (checkout) | ✅/❌ |
| Upgrade (immediate prorate) | ✅/❌ |
| Upgrade (end-of-cycle schedule) | ✅/❌ |
| Downgrade | ✅/❌ |
| Cancel at period end | ✅/❌ |
| Cancel immediately | ✅/❌ |
| Reactivation (un-cancel) | ✅/❌ |
| Trial start | ✅/❌ |
| Trial → paid transition | ✅/❌ |
| Payment failure (past_due) | ✅/❌ |
| Default plan fallback | ✅/❌ |
| Usage tracking + billing | ✅/❌/N/A |
| Entitlement resets | ✅/❌/N/A |

### Recommendations (Priority Ordered)
1. ...
```

6. **Be specific**: Include file paths, line numbers, code snippets, and the concrete fix for every finding.
