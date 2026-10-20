---
description: Implement Stripe billing based on BILLING_REQUIREMENTS.md. Generates production-ready code with guardrails for webhooks, entitlements, usage billing, credit systems, lifecycle management, and edge case handling.
argument-hint: [requirements-file-path]
---

# /billingplane:implement

## Purpose
Generate production-ready billing implementation following BillingPlane guardrails. Every pattern is validated against production billing architectures.

## Pre-flight
1. Look for `BILLING_REQUIREMENTS.md` in project root
2. If not found: "Run /billingplane:discover first, or provide requirements inline?"
3. Detect stack from project files
4. Read requirements to determine which steps to execute (skip inapplicable steps)

## Implementation Sequence

Execute IN ORDER. Reference the stripe-billing skill and its reference files throughout.

---

### Step 1: Environment Setup
Create/update `.env.example`:
```
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_...
STRIPE_PRICE_PRO_MONTHLY=price_...
STRIPE_PRICE_PRO_YEARLY=price_...
```
Ensure `.gitignore` includes `.env`, `.env.local`, `.env.*.local`.

### Step 2: Database Schema
Based on detected ORM, generate schema with these tables:

**customers** (or extend existing users table):
- `stripe_customer_id` (unique, nullable)
- `current_plan` / `product_id` (current active plan identifier)

**subscriptions**:
- `id`, `stripe_subscription_id` (unique), `stripe_schedule_id` (nullable)
- `customer_id` (FK), `product_id`, `status` enum (scheduled, active, trialing, past_due, canceled, expired)
- `current_period_start`, `current_period_end`, `trial_ends_at`
- `cancel_at_period_end`, `canceled_at`, `ended_at`, `starts_at` (for scheduled products)
- `collection_method` (charge_automatically, send_invoice)
- `created_at`, `updated_at`

**customer_entitlements** (for feature gating + usage tracking):
- `id`, `subscription_id` (FK), `feature_id`, `customer_id` (FK)
- `balance` (numeric, current usage remaining), `unlimited` (boolean)
- `next_reset_at` (timestamp, when balance resets), `created_at`
- `usage_allowed` (boolean, for metered features)
- `additional_balance` (numeric, for adjustments/credits)

**webhook_events** (idempotency):
- `stripe_event_id` (unique), `event_type`, `processed_at`
- TTL: auto-cleanup events older than 7 days

**usage_events** (if usage billing):
- `id`, `customer_id`, `feature_id`, `value` (numeric), `idempotency_key` (unique nullable)
- `created_at`

**invoices** (optional but recommended):
- `id`, `stripe_invoice_id` (unique), `subscription_id`, `customer_id`
- `status`, `amount_due`, `amount_paid`, `period_start`, `period_end`

Follow patterns from `references/db-schema.md`.

### Step 3: Stripe Config Map
```typescript
// lib/stripe/config.ts
export const PRICE_CONFIG = {
  pro: {
    monthly: process.env.STRIPE_PRICE_PRO_MONTHLY!,
    yearly: process.env.STRIPE_PRICE_PRO_YEARLY!,
  },
  enterprise: {
    monthly: process.env.STRIPE_PRICE_ENTERPRISE_MONTHLY!,
    yearly: process.env.STRIPE_PRICE_ENTERPRISE_YEARLY!,
  },
} as const;

// Validation: every Price ID must be a valid env var
const VALID_PRICE_IDS = new Set(
  Object.values(PRICE_CONFIG).flatMap(tier => Object.values(tier))
);
export const isValidPriceId = (id: string) => VALID_PRICE_IDS.has(id);
```
NEVER hardcode Price IDs or amounts.

### Step 4: Server-Only Stripe Client
Stack-appropriate server-only Stripe initialization. Follow `references/nextjs-patterns.md` or `references/express-patterns.md`.

### Step 5: Checkout Session Endpoint
- Validate `priceId` against `isValidPriceId()` allowlist
- Get or create Stripe Customer (store mapping in DB)
- Include `customer_id` and `product_id` in session metadata
- Set success_url and cancel_url
- Configure trial if requirements specify it: `subscription_data.trial_period_days`
- Allow promotion codes if requirements include coupons

### Step 6: Webhook Handler — Multi-Layer Pipeline

Build a webhook handler following Autumn's proven middleware pattern:

**Layer 1: Signature Verification**
- Use `stripe.webhooks.constructEvent(rawBody, signature, webhookSecret)`
- Raw body MUST be preserved (framework-specific — see reference files)
- Return 400 on verification failure

**Layer 2: Idempotency Check**
- Check `event.id` against webhook_events table (or Redis if available)
- If already processed, return `{ received: true, duplicate: true }` with status 200
- If Redis: use `SET key NX PX 300000` (5-minute TTL, atomic)
- If DB: INSERT with unique constraint, catch conflict

**Layer 3: Customer Resolution**
- Extract `stripeCustomerId` from event object (varies by event type — see mapping below)
- Resolve to internal customer record
- If customer not found and event is not checkout.session.completed, log warning and return 200

**Layer 4: Event Routing**
Route to specific handlers. Handle ALL of these events:

```typescript
switch (event.type) {
  case 'checkout.session.completed':
    await handleCheckoutCompleted(event, customer);
    break;
  case 'customer.subscription.created':
    await handleSubscriptionCreated(event, customer);
    break;
  case 'customer.subscription.updated':
    await handleSubscriptionUpdated(event, customer);
    break;
  case 'customer.subscription.deleted':
    await handleSubscriptionDeleted(event, customer);
    break;
  case 'invoice.created':
    await handleInvoiceCreated(event, customer);     // Usage arrear billing
    break;
  case 'invoice.paid':
    await handleInvoicePaid(event, customer);
    break;
  case 'invoice.payment_failed':
    await handleInvoicePaymentFailed(event, customer);
    break;
  case 'invoice.finalized':
    await handleInvoiceFinalized(event, customer);
    break;
  case 'customer.subscription.trial_will_end':
    await handleTrialWillEnd(event, customer);
    break;
}
```

**Layer 5: Cache Invalidation (post-processing)**
- After handler completes, invalidate any cached customer/subscription state

**Always return 200.** Never return error codes for processing failures.

### Step 7: Subscription.Updated Handler — The Critical Handler

This is the most complex webhook handler. Implement with `previous_attributes` inspection:

```typescript
async function handleSubscriptionUpdated(event, customer) {
  const subscription = event.data.object;
  const previous = event.data.previous_attributes || {};

  // 1. Detect and handle cancellation
  const newlyCanceled =
    (previous.cancel_at_period_end === false && subscription.cancel_at_period_end) ||
    (previous.cancel_at === null && subscription.cancel_at);

  if (newlyCanceled) {
    await handleCancellation(subscription, customer);
    // Schedule default/free product at period end
    await scheduleDefaultProduct(customer, subscription.current_period_end);
  }

  // 2. Detect and handle reactivation (un-cancel)
  const reactivated =
    (previous.cancel_at_period_end === true && !subscription.cancel_at_period_end) ||
    (previous.cancel_at !== null && subscription.cancel_at === null);

  if (reactivated) {
    await handleReactivation(subscription, customer);
    // Remove scheduled default product
    await removeScheduledDefaultProduct(customer);
  }

  // 3. Detect past_due transition
  if (previous.status !== 'past_due' && subscription.status === 'past_due') {
    await handlePastDue(subscription, customer);
  }

  // 4. Detect plan change via schedule (items changed + schedule exists)
  if (previous.items && subscription.schedule) {
    await handleSchedulePhaseChange(subscription, customer);
  }

  // 5. Always sync status to DB
  await syncSubscriptionStatus(subscription, customer);
}
```

### Step 8: Subscription.Deleted Handler

```typescript
async function handleSubscriptionDeleted(event, customer) {
  const subscription = event.data.object;

  // 1. If usage-in-arrear: create final invoice for outstanding usage
  if (hasUsageInArrearPricing(customer)) {
    await createFinalUsageInvoice(subscription, customer);
  }

  // 2. Expire customer's subscription and entitlements
  await expireSubscription(subscription.id);

  // 3. Activate default/free product
  await activateDefaultProduct(customer);
}
```

### Step 9: Entitlement Engine (Check + Track)

> **Full reference:** `skills/stripe-billing/references/feature-gating.md` — covers all check modes, credit system fallback, atomic check+track, entity-level gating, upgrade preview, lazy reset, caching, and Decimal.js precision.
>
> **Requirements + test validation:** `commands/feature-gating-requirements.md` — 21 Q&A questions to set requirements, 56 test cases mapped to each requirement.

**Check endpoint** — called before granting access to any gated feature:
```typescript
// GET /api/entitlements/check?customer_id=X&feature_id=Y
async function checkEntitlement(customerId, featureId, requiredBalance = 1) {
  const entitlement = await getEntitlement(customerId, featureId);

  if (!entitlement) return { allowed: false, reason: 'no_entitlement' };
  if (entitlement.unlimited) return { allowed: true, balance: Infinity };
  if (entitlement.balance >= requiredBalance) return { allowed: true, balance: entitlement.balance };
  return { allowed: false, balance: entitlement.balance, reason: 'insufficient_balance' };
}
```

**Track endpoint** — record usage and deduct from balance:
```typescript
// POST /api/entitlements/track { customer_id, feature_id, value, idempotency_key? }
async function trackUsage(customerId, featureId, value, idempotencyKey?) {
  // Idempotency check if key provided
  if (idempotencyKey) {
    const exists = await checkUsageEventExists(idempotencyKey);
    if (exists) return { duplicate: true };
  }

  // Atomic deduction (DB transaction or Redis Lua)
  const result = await atomicDeduct(customerId, featureId, value);

  if (result.insufficient && overageBehavior === 'reject') {
    throw new Error('insufficient_balance');
  }

  // Record usage event
  await recordUsageEvent(customerId, featureId, value, idempotencyKey);
  return { balance: result.newBalance, allowed: result.success };
}
```

Default DENY: on any error in check/track, deny access. Never grant on uncertainty.

### Step 10: Feature Gating Middleware
Server-side middleware that calls the check endpoint:
```typescript
function requireFeature(featureId: string) {
  return async (req, res, next) => {
    const result = await checkEntitlement(req.user.id, featureId);
    if (!result.allowed) {
      return res.status(403).json({ error: 'feature_not_available', reason: result.reason });
    }
    next();
  };
}
```

### Step 11: Usage-In-Arrear Billing (if applicable)

Handle `invoice.created` webhook to add usage line items:
```typescript
async function handleInvoiceCreated(event, customer) {
  const invoice = event.data.object;
  // Only process subscription cycle invoices
  if (invoice.billing_reason !== 'subscription_cycle') return;
  // Skip if trial just ended (trial usage is free)
  if (isTrialJustEnded(invoice)) return;

  // Get outstanding usage for each metered feature
  const usageLineItems = await calculateArrearLineItems(customer, invoice.period_end);

  for (const item of usageLineItems) {
    await stripe.invoiceItems.create({
      customer: invoice.customer,
      invoice: invoice.id,
      description: item.description,
      amount: item.amount,        // In cents, from Stripe pricing
      currency: item.currency,
    });
  }

  // Reset entitlement balances for billed features
  await resetBilledEntitlements(customer, invoice.period_end);
}
```

### Step 12: Credit System (if applicable)

If requirements include a credit/token system:
- Credits shared across multiple features
- Each feature has a "cost" in credits per use
- Atomic deduction from credit pool
- Recharge on subscription renewal (via invoice.paid)
- Overage: block, or allow and bill excess

```typescript
// Deduct credits atomically
async function deductCredits(customerId, amount) {
  // Use DB transaction with SELECT FOR UPDATE or Redis Lua
  const result = await db.transaction(async (tx) => {
    const ent = await tx.selectFrom('customer_entitlements')
      .where('customer_id', '=', customerId)
      .where('feature_id', '=', 'credits')
      .forUpdate()
      .executeTakeFirst();

    if (ent.balance < amount && overageBehavior === 'reject') {
      throw new InsufficientBalanceError();
    }

    await tx.updateTable('customer_entitlements')
      .set({ balance: Math.max(0, ent.balance - amount) })
      .where('id', '=', ent.id)
      .execute();

    return { newBalance: Math.max(0, ent.balance - amount) };
  });
  return result;
}
```

### Step 13: Subscription Management Endpoints
- `GET /api/billing/status` — current plan, subscription status, entitlement balances
- `POST /api/billing/portal` — create Stripe Customer Portal session
- `POST /api/billing/cancel` — set `cancel_at_period_end` (NEVER delete immediately from client)
- `POST /api/billing/reactivate` — remove `cancel_at_period_end`
- `POST /api/billing/upgrade` — create checkout session for new plan (or use Subscription Schedules for end-of-cycle)
- `POST /api/billing/downgrade` — schedule downgrade for end of period

### Step 14: Success/Cancel Pages
- Success page: Poll `GET /api/billing/status` every 2 seconds until webhook-confirmed subscription active
- NEVER grant access based on redirect query params
- Cancel page: Show return to pricing option

### Step 15: Trial Management (if applicable)
- Store `trial_ends_at` from subscription object
- Handle `trial_will_end` event: send reminder email/notification
- On trial→paid: entitlements already activated via subscription.updated status sync
- On trial expire without payment: subscription.deleted fires → activate default plan

### Step 16: Default Product Fallback
When any paid subscription ends (cancel, expire, delete):
- Activate a free-tier product with its own entitlements
- Schedule activation for `current_period_end` if cancel_at_period_end
- Immediate activation if subscription deleted

### Step 17: Entitlement Reset Cron (if usage billing)
```typescript
// Run every hour (or use lazy reset on check)
async function resetExpiredEntitlements() {
  const expired = await db.select()
    .from('customer_entitlements')
    .where('next_reset_at', '<=', new Date())
    .where('unlimited', '=', false);

  for (const ent of expired) {
    const startingBalance = getStartingBalance(ent); // From plan config
    await db.update('customer_entitlements')
      .set({
        balance: startingBalance,
        next_reset_at: calculateNextResetAt(ent),
      })
      .where('id', '=', ent.id);
  }
}
```
Alternative: Lazy reset — check `next_reset_at` on every entitlement check, reset inline if expired.

### Step 18: Admin Safety Net
- `POST /api/admin/sync-subscription/:customerId` — fetch latest from Stripe, reconcile DB
- `POST /api/admin/grant-entitlement` — manually adjust entitlement balance
- `GET /api/admin/audit-log` — list recent webhook events and processing results

---

## Post-Implementation

After generating all code:
1. List all files created/modified with line counts
2. Run `/billingplane:audit` on generated code — must produce zero CRITICAL violations
3. Output testing checklist:
```
## Testing Checklist
1. Start Stripe CLI: stripe listen --forward-to localhost:3000/api/webhooks/stripe
2. Create test checkout: stripe trigger checkout.session.completed
3. Verify subscription created in DB
4. Test feature gating: call protected endpoint without subscription (expect 403)
5. Test upgrade: trigger customer.subscription.updated with plan change
6. Test cancel: trigger subscription canceled, verify default plan activates
7. Test payment failure: trigger invoice.payment_failed, verify grace period
8. Test usage tracking: POST /api/entitlements/track, verify balance decreases
9. Test usage billing: trigger invoice.created, verify line items added
10. Test idempotency: replay a webhook event, verify no duplicate processing
```

## Code Quality Rules
- TypeScript strict mode
- All Stripe API calls in try/catch
- No `any` types for Stripe objects
- Comments explain WHY (business rule), not WHAT (obvious code)
- Guard clauses over nested conditionals
- Object parameters for functions (not positional args)
