# Subscription Lifecycle Reference

Complete lifecycle management patterns validated against Autumn's production system.

## Status State Machine

```
[new] → trialing → active → past_due → canceled → expired
                ↓         ↑       ↓
          (trial end)  (payment)  (grace period)
                ↓         ↓
             active    canceled
```

Autumn's status enum: `Scheduled | Active | Trialing | PastDue | Expired | Unknown`

## Cancellation — Three Variants

### 1. Cancel at Period End (most common)
```typescript
// User cancels, keeps access until cycle ends
await stripe.subscriptions.update(subId, { cancel_at_period_end: true });
```
Detection in subscription.updated:
```typescript
const prev = event.data.previous_attributes;
const newlyCanceled = prev?.cancel_at_period_end === false && subscription.cancel_at_period_end;
```
On cancel:
- Mark subscription `canceled_at = now`, keep status `active`
- Schedule default/free product to activate at `current_period_end`
- When period ends: `subscription.deleted` fires → expire + activate default

### 2. Cancel at Specific Date
```typescript
await stripe.subscriptions.update(subId, { cancel_at: Math.floor(futureDate / 1000) });
```
Detection: `prev.cancel_at === null && subscription.cancel_at !== null`

### 3. Immediate Cancellation
```typescript
await stripe.subscriptions.cancel(subId);
// Fires subscription.deleted immediately
```

## Reactivation (Un-Cancel)

When user reverses cancellation before period ends:
```typescript
await stripe.subscriptions.update(subId, { cancel_at_period_end: false });
```
Detection:
```typescript
const reactivated = prev?.cancel_at_period_end === true && !subscription.cancel_at_period_end;
// OR
const uncanceledAt = prev?.cancel_at !== null && subscription.cancel_at === null;
```
Handler must:
1. Clear `canceled_at` and `cancel_at_period_end` in DB
2. Remove any scheduled default product (it's no longer needed)
3. Log reactivation event

## Past Due Handling

Transition: `active` → `past_due` when payment fails.
```typescript
const wentPastDue = prev?.status !== 'past_due' && subscription.status === 'past_due';
```
Options (configurable per org):
- **Grace period**: Keep access for X days, send dunning emails
- **Cancel on past_due**: Immediately cancel (Autumn's `cancel_on_past_due` config)
- **Downgrade**: Switch to limited free tier while past_due

Autumn's approach: configurable per organization. Check `org.config.cancel_on_past_due`.

```typescript
if (wentPastDue) {
  if (config.cancel_on_past_due) {
    // Void the failed invoice and cancel
    await stripe.invoices.voidInvoice(latestInvoice.id);
    await stripe.subscriptions.cancel(subscription.id);
  } else {
    // Start grace period timer
    await startGracePeriod(customerId, config.grace_period_days);
  }
}
```

## Default Product Fallback

Critical pattern: users must NEVER be in a state with zero entitlements.

```typescript
async function scheduleDefaultProduct(customerId, activateAt) {
  const defaultProduct = await getDefaultProduct(); // Free tier
  if (!defaultProduct) return; // No free tier configured

  await db.insert('subscriptions').values({
    customer_id: customerId,
    product_id: defaultProduct.id,
    status: 'scheduled',
    starts_at: activateAt,
  });

  // Create entitlements for default product (inactive until starts_at)
  for (const feature of defaultProduct.features) {
    await db.insert('customer_entitlements').values({
      customer_id: customerId,
      feature_id: feature.id,
      balance: feature.default_balance,
      subscription_id: null, // Will be linked when activated
    });
  }
}

async function activateDefaultProduct(customerId) {
  const scheduled = await db.select()
    .from('subscriptions')
    .where('customer_id', '=', customerId)
    .where('status', '=', 'scheduled')
    .where('starts_at', '<=', Date.now())
    .first();

  if (scheduled) {
    await db.update('subscriptions')
      .set({ status: 'active', starts_at: null })
      .where('id', '=', scheduled.id);
  }
}
```

## Trial Management

### Setup
```typescript
const session = await stripe.checkout.sessions.create({
  subscription_data: {
    trial_period_days: 14,
    trial_settings: { end_behavior: { missing_payment_method: 'cancel' } },
  },
});
```

### Trial → Paid Transition
When trial ends with valid payment method, Stripe creates subscription cycle.
- `subscription.updated` fires with status change `trialing` → `active`
- `invoice.paid` fires for the first real payment
- Entitlements already active from trial start (no action needed)

### Trial Expires Without Payment
- `subscription.updated` fires with status → `past_due` or `canceled`
- `subscription.deleted` fires
- Activate default product fallback

### Trial Just Ended Detection (for Usage Billing)
Autumn pattern: skip arrear billing for trial period usage.
```typescript
function hasTrialJustEnded(subscription, invoice) {
  return subscription.trial_end &&
    subscription.trial_end === Math.floor(invoice.period_start);
}
```

### trial_will_end Event
Fires 3 days before trial ends. Use for:
- Sending "trial ending soon" email
- Prompting user to add payment method
- Pre-creating checkout for easy conversion

## Upgrade/Downgrade Patterns

### Immediate Upgrade with Proration
```typescript
await stripe.subscriptions.update(subId, {
  items: [{ id: itemId, price: newPriceId }],
  proration_behavior: 'create_prorations',
});
```
- Stripe calculates proration automatically
- `subscription.updated` fires with changed items
- Update entitlements to new plan immediately

### End-of-Cycle Upgrade via Subscription Schedule
Autumn uses Subscription Schedules for deferred plan changes:
```typescript
// Create schedule from existing subscription
const schedule = await stripe.subscriptionSchedules.create({
  from_subscription: subId,
});

// Add phase for new plan starting at next billing period
await stripe.subscriptionSchedules.update(schedule.id, {
  phases: [
    { /* current phase */ },
    {
      items: [{ price: newPriceId }],
      start_date: subscription.current_period_end,
    },
  ],
});
```
- At period boundary: `subscription.updated` fires with items changed + schedule reference
- Handler detects `prev.items` changed + `subscription.schedule` exists
- Activate new entitlements, expire old ones
- Release schedule if last phase reached

### Upgrade Detection
Autumn compares prices to determine upgrade vs downgrade:
```typescript
function isUpgrade(currentPrices, newPrices) {
  const currentTotal = currentPrices.reduce((sum, p) => sum + p.unit_amount, 0);
  const newTotal = newPrices.reduce((sum, p) => sum + p.unit_amount, 0);
  return newTotal > currentTotal;
}
```

## Subscription Locks

Prevent concurrent webhook + API mutations from conflicting:
```typescript
// Redis lock before subscription mutation
const lockKey = `sub_lock:${subscriptionId}`;
const acquired = await redis.set(lockKey, 'locked', 'NX', 'PX', 30000); // 30s TTL

if (!acquired) {
  // Another process is modifying this subscription
  throw new ConcurrentModificationError();
}

try {
  await modifySubscription(subscriptionId);
} finally {
  await redis.del(lockKey);
}
```

In webhook handler, check for lock:
```typescript
const lock = await redis.get(`sub_lock:${subscriptionId}`);
if (lock) {
  // Autumn-initiated change, skip webhook processing
  logger.info('Subscription locked, skipping webhook');
  return;
}
```
