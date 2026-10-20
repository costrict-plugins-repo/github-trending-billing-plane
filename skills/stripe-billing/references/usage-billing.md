# Usage Billing Reference

Patterns validated against Autumn's production usage billing system.

## Billing Types

| Type | Description | When to Use |
|------|-------------|-------------|
| `usage_in_arrear` | Track usage during cycle, bill at end | API calls, compute time, bandwidth |
| `usage_in_advance` | Prepay for allocation, deduct as used | Credit packs, prepaid tokens |
| `usage_below_threshold` | Bill when balance drops below threshold | Top-up style credits |
| `fixed_cycle` | Fixed recurring charge | Standard subscriptions |
| `one_off` | Single charge | One-time purchases, add-ons |
| `in_arrear_prorated` | Arrear billing with mid-cycle proration | Seat-based with mid-cycle changes |

## Feature Types

| Type | Behavior | Example |
|------|----------|---------|
| `boolean` | Access gate, no metering | "Has dashboard access" |
| `metered` | Tracked usage with limits | "API calls: 1000/month" |
| `credit_system` | Deductible balance, multi-feature | "AI tokens shared across features" |

## Usage-In-Arrear Implementation

### invoice.created Handler (Critical)
When Stripe creates a renewal invoice, you MUST add usage line items before it finalizes:

```typescript
async function handleInvoiceCreated(event) {
  const invoice = event.data.object;

  // Only process subscription cycle invoices
  if (invoice.billing_reason !== 'subscription_cycle') return;

  // Skip if trial just ended — trial usage is free
  // Autumn pattern: check if current_period_start === trial_end
  const subscription = await stripe.subscriptions.retrieve(invoice.subscription);
  if (subscription.trial_end && subscription.trial_end === invoice.period_start) return;

  // Calculate usage for each metered feature in the ending period
  const entitlements = await getCustomerEntitlements(customerId);

  for (const ent of entitlements) {
    if (!isMeteredBilling(ent)) continue;

    const usage = calculateUsageForPeriod(ent, invoice.period_start, invoice.period_end);
    if (usage.amount <= 0) continue;

    // Add line item to the invoice
    await stripe.invoiceItems.create({
      customer: invoice.customer,
      invoice: invoice.id,
      amount: usage.amount, // In cents
      currency: 'usd',
      description: `${ent.feature_name}: ${usage.quantity} units @ ${usage.unit_price}/unit`,
    });
  }

  // Reset entitlement balances for billed features
  await resetBilledEntitlements(customerId, invoice.period_end);
}
```

### Final Invoice on Subscription Deletion
Autumn pattern: when subscription with usage is deleted, create a final invoice:

```typescript
async function handleSubscriptionDeleted(event) {
  const subscription = event.data.object;

  // Check for outstanding usage-in-arrear balances
  const usageItems = await calculateOutstandingUsage(customerId, subscription);

  if (usageItems.length > 0) {
    // Create invoice items (they auto-attach to next invoice)
    for (const item of usageItems) {
      await stripe.invoiceItems.create({
        customer: subscription.customer,
        amount: item.amount,
        currency: 'usd',
        description: `Final usage: ${item.description}`,
      });
    }

    // Create and finalize the invoice
    const invoice = await stripe.invoices.create({
      customer: subscription.customer,
      auto_advance: true,
    });
  }

  // Then expire entitlements and activate default plan
}
```

## Atomic Usage Tracking

### Redis Lua Pattern (Autumn uses this for high-throughput)
```lua
-- Atomic deduct from customer entitlement balance
-- Keys: [entitlement_key]
-- Args: [deduct_amount, min_balance]
local current = tonumber(redis.call('GET', KEYS[1]) or '0')
local deduct = tonumber(ARGV[1])
local min_balance = tonumber(ARGV[2] or '0')

if current - deduct < min_balance then
  return {0, current} -- Insufficient balance
end

local new_balance = current - deduct
redis.call('SET', KEYS[1], tostring(new_balance))
return {1, new_balance} -- Success
```

### DB Transaction Pattern (simpler, lower throughput)
```typescript
async function atomicDeduct(customerId, featureId, amount) {
  return await db.transaction(async (tx) => {
    // Lock the row
    const ent = await tx.query(
      `SELECT * FROM customer_entitlements
       WHERE customer_id = $1 AND feature_id = $2
       FOR UPDATE`,
      [customerId, featureId]
    );

    if (!ent || (!ent.unlimited && ent.balance < amount)) {
      return { success: false, balance: ent?.balance ?? 0 };
    }

    if (!ent.unlimited) {
      await tx.query(
        `UPDATE customer_entitlements SET balance = balance - $1 WHERE id = $2`,
        [amount, ent.id]
      );
    }

    return { success: true, balance: ent.unlimited ? Infinity : ent.balance - amount };
  });
}
```

## Overage Behavior

| Behavior | Description | Implementation |
|----------|-------------|----------------|
| `cap` | Stop at zero, deny further usage | Check balance >= required before deducting |
| `reject` | Deny request that would exceed limit | Return 403 if balance < required |
| `allow+bill` | Allow negative balance, bill overage at cycle end | Allow deduction below zero, include in arrear invoice |

## Entitlement Reset

Autumn uses TWO reset strategies:

1. **Cron-based reset**: Background job runs periodically, resets entitlements where `next_reset_at <= now()`
2. **Lazy reset**: On every `check` call, if `next_reset_at <= now()`, reset inline before checking

Recommendation: Use lazy reset for correctness + cron as a catch-up for bulk resets.

```typescript
// Lazy reset pattern
async function checkEntitlement(customerId, featureId) {
  const ent = await getEntitlement(customerId, featureId);

  // Lazy reset if past due
  if (ent.next_reset_at && ent.next_reset_at <= Date.now()) {
    const startingBalance = getStartingBalance(ent.feature_config);
    await updateEntitlement(ent.id, {
      balance: startingBalance,
      next_reset_at: calculateNextResetAt(ent),
    });
    ent.balance = startingBalance;
  }

  return { allowed: ent.unlimited || ent.balance > 0, balance: ent.balance };
}
```

## Credit System Pattern

Credits are a shared balance pool that multiple features deduct from:

```typescript
// Feature costs in credits
const CREDIT_COSTS = {
  'ai_chat': 1,        // 1 credit per chat message
  'ai_image': 10,      // 10 credits per image generation
  'ai_analysis': 5,    // 5 credits per analysis
};

async function useFeature(customerId, featureId) {
  const cost = CREDIT_COSTS[featureId];
  const result = await atomicDeduct(customerId, 'credits', cost);
  if (!result.success) throw new InsufficientCreditsError();
  return result;
}
```

Recharge credits on subscription renewal (handle in `invoice.paid`):
```typescript
async function handleInvoicePaid(event) {
  const invoice = event.data.object;
  if (invoice.billing_reason !== 'subscription_cycle') return;

  // Get plan's credit allocation
  const creditAllocation = getPlanCreditAllocation(customer.plan);

  // Reset or add credits
  await db.update('customer_entitlements')
    .set({ balance: creditAllocation })
    .where('customer_id', '=', customerId)
    .where('feature_id', '=', 'credits');
}
```
