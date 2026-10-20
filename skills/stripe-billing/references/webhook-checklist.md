# Webhook Handling Checklist

## Required Event Handlers

| Event | Tier | Purpose | Key Actions |
|-------|------|---------|-------------|
| `checkout.session.completed` | 1 | New purchase | Create/link customer, create subscription record, create entitlements |
| `customer.subscription.created` | 1 | Subscription started | Record subscription, initialize entitlements if not from checkout |
| `customer.subscription.updated` | 1 | Status/plan changes | Detect: cancellation, reactivation, past_due, plan change, schedule phase change (via `previous_attributes`) |
| `customer.subscription.deleted` | 1 | Subscription ended | Final arrear invoice, expire entitlements, activate default product |
| `invoice.paid` | 1 | Payment succeeded | Confirm subscription active, recharge credits, handle rewards/receipts |
| `invoice.created` | 2 | Invoice being built | Add usage-in-arrear line items before finalization |
| `invoice.finalized` | 2 | Invoice finalized | Store invoice record, finalize line items |
| `invoice.payment_failed` | 2 | Payment failed | Handle past_due, dunning, grace period, notify user |
| `invoice.updated` | 3 | Invoice modified | Sync invoice status |
| `customer.subscription.trial_will_end` | 3 | Trial ending soon | Send reminder email, prompt payment method |
| `subscription_schedule.canceled` | 3 | Schedule canceled | Clean up scheduled products |
| `customer.discount.deleted` | 3 | Discount removed | Update discount/coupon state |

## Middleware Pipeline (Autumn-validated order)

```
Request
  → 1. Signature Verification (constructEvent with raw body)
  → 2. Idempotency Check (Redis SET NX PX or DB unique constraint)
  → 3. Customer Resolution (stripe customer ID → internal customer)
  → 4. Structured Logging (event type, org, customer context)
  → 5. Event Handler (specific logic per event type)
  → 6. Cache Invalidation (clear cached customer state)
  → Return 200 (ALWAYS, even on processing errors)
```

## Customer ID Extraction by Event Type

```typescript
function getStripeCustomerId(event) {
  switch (event.type) {
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted':
    case 'checkout.session.completed':
    case 'invoice.paid':
    case 'invoice.created':
    case 'invoice.updated':
    case 'invoice.finalized':
    case 'subscription_schedule.canceled':
      return event.data.object.customer;  // All have .customer field

    case 'customer.discount.deleted':
      return event.data.object.id;        // Customer object itself

    case 'invoice.payment_failed':
      return event.data.object.customer;

    default:
      return null;
  }
}
```

## Idempotency Pattern

### Redis (recommended for production)
```typescript
const IDEMPOTENCY_TTL_MS = 5 * 60 * 1000; // 5 minutes
const key = `stripe:webhook:${event.id}`;

const result = await redis.set(key, Date.now().toString(), 'PX', IDEMPOTENCY_TTL_MS, 'NX');

if (result === null) {
  // Duplicate — already processing or processed
  return { received: true, duplicate: true };
}

// On Redis failure: FAIL OPEN (process the event, risk duplicate over missing)
```

### DB (simpler, acceptable for lower volume)
```typescript
try {
  await db.insert('webhook_events').values({
    stripe_event_id: event.id,
    event_type: event.type,
    processed_at: new Date(),
  });
} catch (e) {
  if (isUniqueViolation(e)) {
    return { received: true, duplicate: true };
  }
  throw e;
}
```

## Testing with Stripe CLI

```bash
# Forward webhooks to local server
stripe listen --forward-to localhost:3000/api/webhooks/stripe

# Trigger specific events
stripe trigger checkout.session.completed
stripe trigger customer.subscription.updated
stripe trigger customer.subscription.deleted
stripe trigger invoice.paid
stripe trigger invoice.payment_failed

# Trigger with specific subscription status
stripe trigger customer.subscription.updated --override customer.subscription.updated:status=past_due
```

## Common Mistakes

1. **Not using raw body**: `express.json()` parses body before signature verification → verification fails
2. **Returning 500 on errors**: Stripe retries → duplicate processing. Always return 200.
3. **Not handling event ordering**: `invoice.paid` may arrive before `checkout.session.completed`. Each handler must be independently correct.
4. **Trusting checkout.session.completed alone**: Not sufficient for subscription activation. Wait for `customer.subscription.created` or `invoice.paid` for confirmation.
5. **Ignoring previous_attributes**: Treating every `subscription.updated` the same misses cancellation, reactivation, and status transitions.
6. **No final invoice on deletion**: Usage-in-arrear customers get free usage in their last period.
7. **No default product fallback**: Users end up with zero entitlements after cancellation.
