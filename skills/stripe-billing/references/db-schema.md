# Database Schema Reference

Production-grade schema patterns validated against Autumn's architecture.

## Core Tables

### Prisma Schema

```prisma
model User {
  id                String   @id @default(cuid())
  email             String   @unique
  stripeCustomerId  String?  @unique @map("stripe_customer_id")
  createdAt         DateTime @default(now()) @map("created_at")
  updatedAt         DateTime @updatedAt @map("updated_at")

  subscriptions        Subscription[]
  customerEntitlements CustomerEntitlement[]
  usageEvents          UsageEvent[]
  @@map("users")
}

model Subscription {
  id                      String   @id @default(cuid())
  userId                  String   @map("user_id")
  stripeSubscriptionId    String?  @unique @map("stripe_subscription_id")
  stripeScheduleId        String?  @map("stripe_schedule_id")
  productId               String   @map("product_id")

  status                  SubscriptionStatus @default(ACTIVE)
  currentPeriodStart      DateTime? @map("current_period_start")
  currentPeriodEnd        DateTime? @map("current_period_end")
  trialEndsAt             DateTime? @map("trial_ends_at")

  cancelAtPeriodEnd       Boolean  @default(false) @map("cancel_at_period_end")
  canceledAt              DateTime? @map("canceled_at")
  endedAt                 DateTime? @map("ended_at")
  startsAt                DateTime? @map("starts_at") // For scheduled subscriptions

  collectionMethod        String   @default("charge_automatically") @map("collection_method")

  createdAt               DateTime @default(now()) @map("created_at")
  updatedAt               DateTime @updatedAt @map("updated_at")

  user                    User @relation(fields: [userId], references: [id], onDelete: Cascade)
  customerEntitlements    CustomerEntitlement[]
  @@map("subscriptions")
}

enum SubscriptionStatus {
  SCHEDULED
  ACTIVE
  TRIALING
  PAST_DUE
  CANCELED
  EXPIRED
}

model CustomerEntitlement {
  id                String   @id @default(cuid())
  userId            String   @map("user_id")
  subscriptionId    String?  @map("subscription_id")
  featureId         String   @map("feature_id")

  balance           Float    @default(0)
  unlimited         Boolean  @default(false)
  usageAllowed      Boolean  @default(false) @map("usage_allowed")
  additionalBalance Float    @default(0) @map("additional_balance")

  nextResetAt       DateTime? @map("next_reset_at")
  expiresAt         DateTime? @map("expires_at")

  createdAt         DateTime @default(now()) @map("created_at")
  updatedAt         DateTime @updatedAt @map("updated_at")

  user              User @relation(fields: [userId], references: [id], onDelete: Cascade)
  subscription      Subscription? @relation(fields: [subscriptionId], references: [id], onDelete: Cascade)
  @@unique([userId, featureId, subscriptionId])
  @@map("customer_entitlements")
}

model WebhookEvent {
  id                String   @id @default(cuid())
  stripeEventId     String   @unique @map("stripe_event_id")
  eventType         String   @map("event_type")
  processedAt       DateTime @default(now()) @map("processed_at")
  @@map("webhook_events")
}

model UsageEvent {
  id              String   @id @default(cuid())
  userId          String   @map("user_id")
  featureId       String   @map("feature_id")
  value           Float
  idempotencyKey  String?  @unique @map("idempotency_key")
  createdAt       DateTime @default(now()) @map("created_at")

  user            User @relation(fields: [userId], references: [id], onDelete: Cascade)
  @@map("usage_events")
}

model Invoice {
  id                String   @id @default(cuid())
  stripeInvoiceId   String   @unique @map("stripe_invoice_id")
  userId            String   @map("user_id")
  subscriptionId    String?  @map("subscription_id")
  status            String
  amountDue         Int      @map("amount_due")  // In cents
  amountPaid        Int      @map("amount_paid")  // In cents
  periodStart       DateTime @map("period_start")
  periodEnd         DateTime @map("period_end")
  createdAt         DateTime @default(now()) @map("created_at")
  @@map("invoices")
}
```

### Drizzle Alternative

```typescript
import { pgTable, text, numeric, boolean, unique, pgEnum, timestamp } from 'drizzle-orm/pg-core';

export const subscriptionStatus = pgEnum('subscription_status', [
  'scheduled', 'active', 'trialing', 'past_due', 'canceled', 'expired'
]);

export const subscriptions = pgTable('subscriptions', {
  id: text('id').primaryKey().notNull(),
  userId: text('user_id').notNull(),
  stripeSubscriptionId: text('stripe_subscription_id').unique(),
  stripeScheduleId: text('stripe_schedule_id'),
  productId: text('product_id').notNull(),
  status: subscriptionStatus('status').default('active'),
  currentPeriodStart: numeric('current_period_start', { mode: 'number' }),
  currentPeriodEnd: numeric('current_period_end', { mode: 'number' }),
  trialEndsAt: numeric('trial_ends_at', { mode: 'number' }),
  cancelAtPeriodEnd: boolean('cancel_at_period_end').default(false),
  canceledAt: numeric('canceled_at', { mode: 'number' }),
  endedAt: numeric('ended_at', { mode: 'number' }),
  startsAt: numeric('starts_at', { mode: 'number' }),
  collectionMethod: text('collection_method').default('charge_automatically'),
  createdAt: numeric('created_at', { mode: 'number' }),
});

export const customerEntitlements = pgTable('customer_entitlements', {
  id: text('id').primaryKey().notNull(),
  userId: text('user_id').notNull(),
  subscriptionId: text('subscription_id'),
  featureId: text('feature_id').notNull(),
  balance: numeric('balance', { mode: 'number' }).default(0),
  unlimited: boolean('unlimited').default(false),
  usageAllowed: boolean('usage_allowed').default(false),
  additionalBalance: numeric('additional_balance', { mode: 'number' }).default(0),
  nextResetAt: numeric('next_reset_at', { mode: 'number' }),
  expiresAt: numeric('expires_at', { mode: 'number' }),
  createdAt: numeric('created_at', { mode: 'number' }),
});

export const webhookEvents = pgTable('webhook_events', {
  id: text('id').primaryKey().notNull(),
  stripeEventId: text('stripe_event_id').unique().notNull(),
  eventType: text('event_type').notNull(),
  processedAt: numeric('processed_at', { mode: 'number' }),
});

export const usageEvents = pgTable('usage_events', {
  id: text('id').primaryKey().notNull(),
  userId: text('user_id').notNull(),
  featureId: text('feature_id').notNull(),
  value: numeric('value', { mode: 'number' }).notNull(),
  idempotencyKey: text('idempotency_key').unique(),
  createdAt: numeric('created_at', { mode: 'number' }),
});
```

## Design Decisions

1. **Separate subscriptions table**: Don't put subscription fields on the users table. Users can have multiple subscriptions (scheduled, active), and subscription lifecycle is complex enough to warrant its own table.

2. **Store `currentPeriodEnd`**: Critical for post-cancellation access. User who cancels at period end keeps access until this date.

3. **`startsAt` for scheduled subscriptions**: When downgrade is deferred to end-of-cycle, the new subscription is created with `status: scheduled` and `startsAt: currentPeriodEnd`.

4. **Customer entitlements separate from subscriptions**: Entitlements can exist without a subscription (free tier, manual grants, credits), and multiple entitlements can exist per feature (from subscription + manual adjustment).

5. **Usage events as append-only log**: Never update usage events. They're an audit trail. Balance deductions happen on `customer_entitlements.balance`.

6. **Webhook events for idempotency**: Minimal table — just event ID and timestamp. Auto-cleanup events older than 7 days to prevent unbounded growth.

## Access Check Query

```sql
-- Does user have access? (active or trialing, or canceled but before period end)
SELECT s.status, s.current_period_end, s.cancel_at_period_end
FROM subscriptions s
WHERE s.user_id = $1
  AND s.status IN ('active', 'trialing', 'past_due')
  AND (s.ended_at IS NULL OR s.ended_at > NOW())
ORDER BY s.created_at DESC
LIMIT 1;

-- Entitlement check (with lazy reset)
SELECT ce.*, ce.balance, ce.unlimited, ce.next_reset_at
FROM customer_entitlements ce
JOIN subscriptions s ON ce.subscription_id = s.id
WHERE ce.user_id = $1
  AND ce.feature_id = $2
  AND s.status IN ('active', 'trialing')
LIMIT 1;
```
