---
description: Stripe billing guardrails for SaaS applications. Auto-activates when working with Stripe, payments, subscriptions, webhooks, checkout, entitlements, usage billing, credit systems, or billing lifecycle management.
keywords: stripe, billing, payments, subscriptions, webhooks, checkout, entitlements, usage-based, credits, metering, SaaS billing, pricing, plans, invoices, arrear billing
---

# Stripe Billing Guardrails

## The 15 Non-Negotiable Rules

Every billing implementation MUST follow these rules. Violations are flagged by severity.

### Security & Data Integrity

**Rule 1: Never hardcode prices or amounts** 🔴 CRITICAL
All Price IDs and amounts come from environment variables or a validated config map.
```typescript
// 🔴 VIOLATION
const session = await stripe.checkout.sessions.create({ line_items: [{ price: 'price_1234', quantity: 1 }] });
// ✅ CORRECT
const session = await stripe.checkout.sessions.create({ line_items: [{ price: PRICE_CONFIG.pro.monthly, quantity: 1 }] });
```

**Rule 2: Stripe secret key — server-side ONLY** 🔴 CRITICAL
Never expose `sk_live_*` or `sk_test_*` in client bundles, SSR props, or API responses.

**Rule 3: Frontend only references publishable key + Price IDs** 🟡 HIGH
Client code may use `pk_test_*`/`pk_live_*` and Price IDs (for display). Never secret keys, webhook secrets, or customer objects.

### State Management

**Rule 4: All billing state changes via webhooks** 🔴 CRITICAL
Never write subscription status, entitlements, or access from checkout redirect, API response, or frontend event. Only the webhook handler writes billing state.

**Rule 5: Success page never implies payment success** 🟡 HIGH
Success redirect page MUST poll a server endpoint for webhook-confirmed state. Show "Confirming your subscription..." spinner, not "Welcome to Pro!"

**Rule 6: Feature access never from UI state alone** 🟡 HIGH
Always check entitlements server-side. Client-cached plan state is a display hint, not an access gate.

### Webhook Handling

**Rule 7: Webhook signature verification mandatory** 🔴 CRITICAL
Every webhook endpoint MUST call `constructEvent(rawBody, signature, secret)` before processing. Raw body must be preserved (no JSON parsing before verification).

**Rule 8: Idempotency per webhook event ID** 🟡 HIGH
Check `event.id` against a dedup store before processing. Preferred: Redis SET NX PX (atomic, TTL-based, fail-open). Acceptable: DB unique constraint with conflict handling.

**Rule 9: subscription.updated MUST inspect previous_attributes** 🔴 CRITICAL — NEW
`customer.subscription.updated` fires for cancellations, reactivations, plan changes, status transitions, and schedule phase changes. Without checking `event.data.previous_attributes`, you cannot differentiate these. Handling them identically causes bugs.
```typescript
// 🔴 VIOLATION — treats all updates the same
case 'customer.subscription.updated':
  await db.subscription.update({ status: subscription.status });
  break;

// ✅ CORRECT — detects state transitions
const prev = event.data.previous_attributes || {};
const newlyCanceled = prev.cancel_at_period_end === false && subscription.cancel_at_period_end;
const reactivated = prev.cancel_at_period_end === true && !subscription.cancel_at_period_end;
const wentPastDue = prev.status !== 'past_due' && subscription.status === 'past_due';
```

### Defensive Defaults

**Rule 10: Default DENY on ambiguity** 🟢 MEDIUM
If entitlement check errors, denies access. If webhook handler can't find customer, returns 200 (don't retry) but doesn't grant access.

**Rule 11: Never compute money — Stripe handles math** 🟢 MEDIUM
No client-side or server-side proration, tax, or discount calculations. Use Stripe's APIs. If you must handle amounts, use integer cents or Decimal.js.

### Lifecycle Safety — NEW from production analysis

**Rule 12: Always schedule default product on cancellation** 🟡 HIGH — NEW
When a paid plan is canceled end-of-cycle, schedule a free/default plan to activate at `current_period_end`. Users must never be in a state with zero entitlements.

**Rule 13: Webhook handler must always return 200** 🟡 HIGH — NEW
Even on processing errors, return 200. Log the error, alert monitoring, but do NOT return 500. Non-200 causes Stripe to retry, creating duplicate processing. Process async if needed.

**Rule 14: Usage billing requires invoice.created handler** 🟡 HIGH — NEW
For usage-in-arrear pricing, you MUST handle `invoice.created` to add usage line items before the invoice finalizes. Missing this = users get free usage.

**Rule 15: Atomic entitlement deductions** 🟢 MEDIUM — NEW
Usage tracking must use atomic operations (DB transaction with SELECT FOR UPDATE, or Redis Lua script). Simple `UPDATE SET balance = balance - X` without isolation allows double-deduction under concurrent requests.

---

## Critical Edge Cases (from production billing systems)

1. **Webhook arrives before checkout redirect**: User is still on "processing..." when webhook writes subscription. Success page must poll.
2. **Dual browser tabs**: User opens checkout in two tabs. Second checkout creates duplicate. Validate no active subscription exists before creating checkout.
3. **Upgrade during invoice processing**: User upgrades while Stripe is generating the renewal invoice. Use subscription locks or handle gracefully.
4. **Trial → paid failure**: Trial ends, payment fails. Subscription goes to `past_due`, not `canceled`. Handle grace period.
5. **Cancel + reactivate before period end**: User cancels, then uncancels. Must clear cancel state AND remove scheduled default product.
6. **Subscription schedule phase change**: Deferred upgrade takes effect at billing boundary. `subscription.updated` fires with changed items + schedule reference. Must activate new entitlements and expire old ones.
7. **Out-of-order webhook delivery**: `invoice.paid` arrives before `checkout.session.completed`. Each handler must be independently idempotent and not assume ordering.
8. **Past due → canceled**: After grace period, Stripe auto-cancels. `subscription.updated` fires with status=canceled, then `subscription.deleted` fires. Both must be handled without conflict.
9. **Usage billing + cancellation**: User cancels with outstanding usage. `subscription.deleted` must create final invoice for remaining usage before expiring entitlements.
10. **Concurrent usage tracking**: Two API requests deduct from same entitlement simultaneously. Without atomic operations, balance goes negative or deduction is lost.

---

## Reference Files

For stack-specific patterns, read the appropriate reference:
- `references/nextjs-patterns.md` — Next.js App Router
- `references/express-patterns.md` — Express/Node.js
- `references/webhook-checklist.md` — Event handling matrix
- `references/db-schema.md` — Database schema patterns
- `references/usage-billing.md` — Usage-in-arrear, credits, metering
- `references/subscription-lifecycle.md` — Cancel, reactivate, upgrade, downgrade, trial, past_due
- `references/feature-gating.md` — Entitlement engine, check/track, credit system fallback, entity-level gating, upgrade preview, caching
