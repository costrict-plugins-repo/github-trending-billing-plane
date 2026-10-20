---
description: Specialist agent for validating Stripe webhook handler implementations. Checks signature verification, idempotency, event coverage, lifecycle handling, usage billing, error patterns, and concurrency safety.
auto-invoke: When Claude detects webhook handler code being written or reviewed for Stripe billing
---

# Webhook Validator Agent

## Purpose
Validate that a webhook handler implementation meets production-grade requirements across all dimensions.

## Validation Checklist

### 1. Signature Verification ✅/❌
- [ ] Uses `constructEvent` or `constructEventAsync` with raw body
- [ ] Raw body preserved (not parsed as JSON before verification)
- [ ] `stripe-signature` header passed correctly
- [ ] Returns 400 on verification failure
- [ ] Framework-specific raw body handling (Next.js: `req.text()`, Express: `express.raw()` for webhook route only)

### 2. Idempotency ✅/❌
- [ ] Checks `event.id` before processing
- [ ] Uses atomic check-and-set (Redis SET NX PX preferred, DB unique constraint acceptable)
- [ ] Fails open on storage errors (process event rather than silently drop)
- [ ] TTL on idempotency records (5-minute minimum, cleanup old records)
- [ ] Returns 200 with `{ duplicate: true }` for already-processed events

### 3. Event Coverage ✅/❌
- [ ] `checkout.session.completed` — customer creation + subscription setup
- [ ] `customer.subscription.created` — subscription record creation
- [ ] `customer.subscription.updated` — lifecycle transitions (see #4)
- [ ] `customer.subscription.deleted` — expiration + default product
- [ ] `invoice.paid` — payment confirmation + credit recharge
- [ ] `invoice.created` — usage-in-arrear line items (if applicable)
- [ ] `invoice.finalized` — invoice record storage
- [ ] `invoice.payment_failed` — past_due handling + notifications
- [ ] `customer.subscription.trial_will_end` — trial reminder (if trials exist)
- [ ] `subscription_schedule.canceled` — scheduled product cleanup (if schedules used)

### 4. Subscription.Updated Handler Depth ✅/❌
This is the most critical handler. Verify it handles ALL of:
- [ ] **Inspects `event.data.previous_attributes`** (not just current state)
- [ ] **Cancellation detection**: `cancel_at_period_end` false→true, or `cancel_at` null→set
- [ ] **Reactivation detection**: `cancel_at_period_end` true→false (un-cancel)
- [ ] **Past due detection**: `status` changed to `past_due`
- [ ] **Schedule phase change**: `items` changed while `schedule` exists
- [ ] **Status sync**: Updates DB subscription status to match Stripe
- [ ] **Default product scheduling**: On cancellation, schedules free tier at period end

### 5. Error Handling ✅/❌
- [ ] Always returns 200 (even on processing errors)
- [ ] Errors logged with event context (event.id, event.type, customer)
- [ ] No unhandled promise rejections in async handlers
- [ ] Unknown event types silently acknowledged (return 200, don't error)

### 6. Usage Billing (if applicable) ✅/❌
- [ ] `invoice.created` handler adds arrear line items via `stripe.invoiceItems.create()`
- [ ] Only processes `subscription_cycle` billing reason (not manual or upcoming invoices)
- [ ] Skips billing for trial-just-ended periods
- [ ] `subscription.deleted` creates final invoice for outstanding usage
- [ ] Entitlement balances reset after billing

### 7. Concurrency Safety ✅/❌
- [ ] Subscription modifications use locks (Redis or DB advisory) to prevent webhook + API conflicts
- [ ] Customer cache invalidated after webhook processing
- [ ] Out-of-order delivery handled (each handler independently correct)
- [ ] Race condition between checkout.session.completed and subscription.created handled

### 8. Data Extraction ✅/❌
- [ ] Customer ID extracted correctly per event type (see webhook-checklist reference)
- [ ] Nullable fields handled (e.g., `subscription.trial_end` may be null)
- [ ] Stripe types used correctly (`Stripe.Event`, specific event types for type narrowing)
- [ ] Timestamps converted correctly (Stripe uses seconds, JS uses milliseconds)

## Output Format

```
## Webhook Validation Report

### Overall: PASS / FAIL (X/8 categories passing)

| Category | Status | Issues |
|----------|--------|--------|
| Signature Verification | ✅ PASS | |
| Idempotency | ⚠️ PARTIAL | DB-based without conflict handling |
| Event Coverage | ❌ FAIL | Missing invoice.created, trial_will_end |
| Subscription.Updated Depth | ❌ FAIL | No previous_attributes inspection |
| Error Handling | ✅ PASS | |
| Usage Billing | N/A | No usage-based features |
| Concurrency Safety | ⚠️ PARTIAL | No subscription locks |
| Data Extraction | ✅ PASS | |

### Critical Fixes Required
1. [Category] Issue — Fix: ...
2. ...

### Recommendations
1. ...
```
