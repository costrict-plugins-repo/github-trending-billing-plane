# Feature Gating Requirements Discovery & Test Validation

> **How to use this file:**
> 1. Walk through each Q&A section with your team
> 2. Record your answers — they become your FEATURE_GATING_REQUIREMENTS.md
> 3. Each answer maps to specific test cases in Section B
> 4. Run the mapped test cases to validate your implementation covers every requirement
>
> Every question has a **Why it matters** note and an **If you skip this** warning.

---

# SECTION A: Requirements Discovery (Q&A)

---

## Phase 1: Feature Inventory

### Q1. List every feature your app gates by plan or payment.

For each feature, classify its type:

| Feature Name | Type | Free Tier | Pro Tier | Enterprise |
|---|---|---|---|---|
| _example: Dashboard_ | `boolean` | ✗ | ✓ | ✓ |
| _example: API calls_ | `metered` | 100/mo | 10,000/mo | unlimited |
| _example: AI tokens_ | `credit_system` | 0 | 1,000/mo | 10,000/mo |

**Type definitions:**
- `boolean` — Customer either has it or doesn't. No numeric limit.
- `metered` — Numeric balance with a limit that resets on a cycle.
- `credit_system` — Shared numeric pool that multiple features draw from.

> **Why it matters:** The type determines your entire check/track/reset logic. A boolean feature needs no balance tracking. A metered feature needs atomic deduction. A credit system needs exchange rate mapping.
>
> **If you skip this:** You'll build the wrong abstraction — either over-engineering booleans with balance tracking, or under-engineering metered features with simple on/off checks that can't handle usage limits.

**Test cases mapped → T1.1, T1.2, T1.3**

---

### Q2. Do any features share a common balance pool (credit system)?

If yes, define the exchange rates:

| Credit System Name | Feature | Feature Amount | Credit Cost |
|---|---|---|---|
| _example: AI Credits_ | GPT-4 calls | 1 call | 10 credits |
| _example: AI Credits_ | GPT-3.5 calls | 1 call | 1 credit |
| _example: AI Credits_ | Image generation | 1 image | 25 credits |

> **Why it matters:** Without exchange rate mapping, the check endpoint can't fall back from "feature has no direct balance" to "but the credit pool covers it." Autumn's `getFeatureToUseForCheck` cascades: direct balance → credit system → deny.
>
> **If you skip this:** Customers with available credits get wrongly denied because the check only looks at the direct feature balance.

**Test cases mapped → T2.1, T2.2, T2.3, T2.4**

---

### Q3. Do you need a product-level check (owns product X) OR only feature-level checks?

- **Product check**: "Does customer own Pro?" — Returns status (active/trialing/canceled/past_due)
- **Feature check**: "Does customer have access to api_calls with 5 units available?" — Returns allowed + balance
- **Both**: Product check for UI display ("show Pro badge"), feature check for enforcement

> **Why it matters:** Product checks are simpler but brittle — they break when you add new plans or grant features via add-ons. Feature checks are robust but require the full entitlement engine.
>
> **If you skip this:** You'll hardcode plan names everywhere (`if plan === 'pro'`) and every pricing change requires a code deploy.

**Test cases mapped → T3.1, T3.2, T3.3**

---

## Phase 2: Usage Tracking

### Q4. For each metered feature, what happens when the limit is hit?

| Feature | Overage Behavior | Details |
|---|---|---|
| _example: API calls_ | `reject` | Return 403, deduct nothing |
| _example: Storage_ | `cap` | Deduct what's available, stop at 0 |
| _example: Compute hours_ | `allow` | Allow negative balance, bill overage at cycle end |

**Behavior definitions:**
- `cap` — Deduct only what's available. Balance floors at 0. Graceful degradation.
- `reject` — If balance < required, deny the entire request. All-or-nothing.
- `allow` — Allow balance to go negative. Bill the overage on the next invoice.

> **Why it matters:** This is a per-feature business decision that changes the deduction logic. `reject` needs a pre-check before deduction. `cap` needs min(requested, available). `allow` needs no floor.
>
> **If you skip this:** All features default to one behavior, which is wrong for at least some of them. Rejecting storage writes when you should cap is a data loss risk. Allowing API overage when you should reject is a revenue leak.

**Test cases mapped → T4.1, T4.2, T4.3, T4.4**

---

### Q5. Do you need atomic check-and-track (send_event)?

- **Yes**: If two users could consume the same resource simultaneously (API calls, seat claims, token deduction)
- **No**: If consumption is naturally serialized (one user uploads a file at a time)

> **Why it matters:** Without atomicity, the classic TOCTOU race condition occurs: check passes for both requests, then both deduct, resulting in negative balance or double-consumption.
>
> **If you skip this:** Under load, your system will occasionally grant access beyond the limit. Autumn's test proves it: 7 concurrent requests against balance=5 must yield exactly 5 allowed and 2 denied.

**Test cases mapped → T5.1, T5.2, T5.3**

---

### Q6. Do you need idempotent usage tracking?

- **Yes**: If the same event could be sent twice (webhook retries, client retries, queue redelivery)
- **No**: If every event is guaranteed to be unique (unlikely in distributed systems)

> **Why it matters:** Without idempotency, a retried webhook or a client timeout-and-retry deducts twice for one event.
>
> **If you skip this:** Usage totals drift upward over time. Customers are charged for phantom usage.

**Test cases mapped → T6.1, T6.2**

---

## Phase 3: Entity-Level Billing

### Q7. Does your app have sub-resources with independent limits?

Examples: workspaces, team members, projects, devices, API keys

| Entity Type | Independent Limits? | Example |
|---|---|---|
| _workspace_ | Yes | Each workspace gets its own 1000 API calls/mo |
| _team member_ | No | Shared pool across all members |
| _project_ | Yes | Each project gets 10GB storage independently |

> **Why it matters:** Entity-level gating requires: (a) entity-scoped balance storage, (b) entity_id in check/track requests, (c) balance distribution across entities when a product is attached, (d) entity-scoped reset.
>
> **If you skip this:** All workspaces share a single pool — one heavy-use workspace starves the others.

**Test cases mapped → T7.1, T7.2, T7.3, T7.4**

---

### Q8. When a new entity is created, how does it get its entitlements?

- **Inherit from product**: Auto-allocate the product's per-entity balance
- **Manual allocation**: Admin assigns limits per entity
- **Shared pool**: Entity draws from the customer-level balance (no independent tracking)

> **Why it matters:** Auto-allocation means entity creation triggers entitlement initialization. Manual means you need an admin API. Shared means entity_id is ignored for balance.
>
> **If you skip this:** New workspaces have zero entitlements until someone manually allocates — broken UX.

**Test cases mapped → T8.1, T8.2**

---

## Phase 4: Balance Lifecycle

### Q9. What is the reset interval for each metered feature?

| Feature | Reset Interval | Anchored To |
|---|---|---|
| _API calls_ | Monthly | Subscription billing cycle start |
| _Daily exports_ | Daily | Midnight UTC |
| _Quarterly reports_ | Quarterly | Subscription start date |

> **Why it matters:** Reset timing must align with billing cycles or the usage period won't match the invoice period. Custom intervals (weekly, quarterly, annual) need explicit cycle-end calculation.
>
> **If you skip this:** Usage resets on the 1st of the month but billing runs on the 15th — half the cycle's usage is "free."

**Test cases mapped → T9.1, T9.2, T9.3**

---

### Q10. Do unused credits/usage roll over to the next cycle?

| Feature | Rollover | Max Rollover | Rollover Expiry |
|---|---|---|---|
| _API calls_ | No | — | — |
| _AI credits_ | Yes | 500 | Expire after 1 month |
| _Storage_ | N/A (cumulative) | — | — |

> **Why it matters:** Rollovers create a separate balance bucket with its own expiry. The check endpoint must sum current-cycle balance + rollover balance. Track must deduct from rollover first (FIFO) or current first (your choice).
>
> **If you skip this:** Customers lose unused credits every cycle even if your pricing page promises rollover — a trust-breaking bug.

**Test cases mapped → T10.1, T10.2, T10.3, T10.4**

---

### Q11. Do any entitlements expire on a fixed date (not cycle-based)?

Examples: promotional credits (expire Dec 31), trial entitlements (expire after 14 days), one-time purchases (access for 1 year)

> **Why it matters:** Loose entitlements (no reset interval) need an `expires_at` field checked on every access. Unlike cycle-based features, they don't reset — they just disappear.
>
> **If you skip this:** Promotional credits granted for a campaign remain valid forever.

**Test cases mapped → T11.1, T11.2**

---

## Phase 5: Subscription Lifecycle Impact on Gating

### Q12. When a paid plan is canceled (end-of-cycle), what happens to entitlements?

- **Keep until period end**: Entitlements remain active until `current_period_end`, then expire
- **Expire immediately**: Revoke access now, even though the cycle isn't over
- **Downgrade to free tier**: Swap to free product's entitlements at period end

> **Why it matters:** Most SaaS products use "keep until period end + downgrade to free." This requires scheduling a default product activation at `current_period_end` in your `subscription.updated` handler.
>
> **If you skip this:** Customer cancels → period ends → subscription.deleted fires → entitlements removed → customer has ZERO access, not even free-tier features. Everything is locked.

**Test cases mapped → T12.1, T12.2, T12.3, T12.4**

---

### Q13. When a customer reactivates (un-cancels), what happens?

- **Restore original entitlements**: Remove the scheduled downgrade, keep current plan
- **Re-grant fresh entitlements**: Reset balances as if newly subscribed

> **Why it matters:** Reactivation must clear the scheduled default product AND restore the cancel_at_period_end flag. Without this, the scheduled downgrade still fires at period end.
>
> **If you skip this:** Customer un-cancels, sees "subscription active" in the UI, but at period end the scheduled downgrade still fires and they lose access.

**Test cases mapped → T13.1, T13.2**

---

### Q14. What happens to entitlements during `past_due` status?

- **Grace period**: Keep full access for N days, then downgrade/cancel
- **Immediate downgrade**: Switch to free tier immediately
- **Keep access**: past_due still passes feature checks (Autumn's default)

> **Why it matters:** Most apps keep access during past_due to avoid punishing temporary payment failures. But you need a maximum grace period before auto-canceling.
>
> **If you skip this:** A customer's card expires, payment fails, and they're immediately locked out — even though Stripe will retry for up to 28 days.

**Test cases mapped → T14.1, T14.2**

---

### Q15. When a customer upgrades mid-cycle, what happens to current usage?

- **Reset balances**: New plan's limits start fresh (most common for upgrades)
- **Carry over usage**: Current usage persists, new limit applies (used 50 of 100, upgrade to 1000, now 50 of 1000)
- **Additive**: New plan's allocation added on top of remaining (had 50 left, add 1000, now 1050)

> **Why it matters:** This is one of the most debated product decisions. "Reset on upgrade" is simpler but can be gamed (upgrade → reset → use → downgrade). "Carry over" is fairer but more complex.
>
> **If you skip this:** Inconsistent behavior — some features reset, others carry over, creating confusion.

**Test cases mapped → T15.1, T15.2, T15.3**

---

### Q16. Do you support trial periods, and how do trials affect entitlements?

- **Full access during trial**: Same entitlements as the paid plan
- **Limited trial entitlements**: Reduced limits during trial
- **Trial usage billed?**: Is usage during trial charged when trial ends?

> **Why it matters:** Trial entitlements must be initialized when the subscription starts (status=trialing), not when the first payment succeeds. And when the trial converts to paid, the system must handle the transition without double-granting.
>
> **If you skip this:** Trial users get no entitlements (can't use the product during trial) or trial usage is billed on the first invoice.

**Test cases mapped → T16.1, T16.2, T16.3, T16.4**

---

## Phase 6: Upgrade Preview & Client Integration

### Q17. When a feature check fails, should the response include upgrade suggestions?

- **Yes**: Return products that would grant the feature, with pricing
- **No**: Just return `allowed: false`

Distinguish two scenarios:
- **Usage limit**: Customer has the feature but ran out (needs more of the same)
- **Feature flag**: Customer's plan doesn't include this feature at all (needs an upgrade)

> **Why it matters:** Upgrade previews power in-app upgrade prompts. Without them, the frontend has to make additional API calls to figure out what to show.
>
> **If you skip this:** Denied users see a generic "limit reached" with no actionable next step. Conversion from free to paid drops.

**Test cases mapped → T17.1, T17.2, T17.3**

---

### Q18. How should the client consume feature gating?

- **Server-side middleware only**: Backend enforces, frontend is blind
- **Client-side hint + server enforcement**: Frontend calls /check for UI (show/hide buttons), backend enforces
- **Publishable key check**: Client can call /check with a public API key (read-only, no tracking)

> **Why it matters:** Client-side checks improve UX (disable buttons, show counters) but must never be the sole enforcement. Publishable keys allow client checks without exposing the secret key.
>
> **If you skip this:** Either the frontend shows features the backend will reject (confusing UX) or you expose your secret API key client-side (security breach).

**Test cases mapped → T18.1, T18.2**

---

## Phase 7: Infrastructure & Safety

### Q19. What is your expected check/track throughput?

| Metric | Value |
|---|---|
| Peak checks per second | _____ |
| Peak tracks per second | _____ |
| Average response time target | _____ ms |

Based on this:
- < 100 QPS: Database-only is fine
- 100–1000 QPS: Add Redis caching for reads, DB for writes
- > 1000 QPS: Redis Lua scripts for atomic check+track, async DB sync

> **Why it matters:** The cache layer and deduction strategy depend on scale. A database SELECT FOR UPDATE at 5000 QPS will choke. Redis Lua at 50 QPS is over-engineering.
>
> **If you skip this:** Either you hit performance walls at scale or you build unnecessary complexity.

**Test cases mapped → T19.1, T19.2**

---

### Q20. What is your failure mode for entitlement checks?

- **Default deny**: If the check fails (DB down, timeout), deny access
- **Default allow**: If the check fails, allow access temporarily
- **Cached fallback**: Use last-known state from cache

> **Why it matters:** Default deny is safer (no revenue leak) but harsher on UX. Default allow risks free access during outages. Cached fallback is the best compromise if your cache is reliable.
>
> **If you skip this:** An unhandled exception in the check endpoint causes a 500 → the client retries → the endpoint is DoS'd → all customers lose access.

**Test cases mapped → T20.1, T20.2**

---

### Q21. Do you need balance adjustment APIs (admin tools)?

- **Set usage**: Override the current usage count (for corrections)
- **Update balance**: Add or subtract from balance (promotional grants, admin adjustments)
- **Create loose entitlement**: Grant a one-off balance not tied to a subscription

> **Why it matters:** Customer support will need to adjust balances. Without admin APIs, every correction requires a database migration.
>
> **If you skip this:** Support tickets for "my usage count is wrong" have no resolution path.

**Test cases mapped → T21.1, T21.2, T21.3**

---

# SECTION B: Test Validation Matrix

> **How to use:** For each requirement you answered YES to in Section A, run the corresponding tests below. Tests are written as behavior specifications — implement them in your test framework of choice.

---

## T1: Feature Type Checks

### T1.1 Boolean Feature — Access Gate
```
SETUP:   Customer "alice" has product "Pro" with boolean feature "dashboard_access"
ACTION:  check(customer_id="alice", feature_id="dashboard_access")
EXPECT:  { allowed: true, balance: null }
REASON:  Boolean features have no balance — existence of entitlement = access
```

### T1.2 Boolean Feature — No Entitlement
```
SETUP:   Customer "bob" has product "Free" which does NOT include "dashboard_access"
ACTION:  check(customer_id="bob", feature_id="dashboard_access")
EXPECT:  { allowed: false, balance: null }
REASON:  No entitlement for this feature on Free plan
```

### T1.3 Metered Feature — Sufficient Balance
```
SETUP:   Customer "alice" has product "Pro" with metered "api_calls" (limit=1000, used=200)
ACTION:  check(customer_id="alice", feature_id="api_calls", required_balance=5)
EXPECT:  { allowed: true, balance: { remaining: 800, granted: 1000, usage: 200 } }
REASON:  800 remaining >= 5 required
```

### T1.4 Metered Feature — Insufficient Balance
```
SETUP:   Customer "alice" has "api_calls" with remaining=3
ACTION:  check(customer_id="alice", feature_id="api_calls", required_balance=5)
EXPECT:  { allowed: false, balance: { remaining: 3 } }
REASON:  3 remaining < 5 required
```

### T1.5 Metered Feature — Unlimited
```
SETUP:   Customer "enterprise" has "api_calls" with unlimited=true
ACTION:  check(customer_id="enterprise", feature_id="api_calls", required_balance=999999)
EXPECT:  { allowed: true, balance: { unlimited: true } }
REASON:  Unlimited flag bypasses all balance checks
```

---

## T2: Credit System

### T2.1 Direct Feature Balance Available
```
SETUP:   Customer has "gpt4_calls" with balance=50 AND "ai_credits" pool with balance=500
         Credit system: 1 gpt4_call = 10 credits
ACTION:  check(customer_id, feature_id="gpt4_calls", required_balance=5)
EXPECT:  { allowed: true } — uses direct "gpt4_calls" balance, NOT credit pool
REASON:  Direct balance takes priority over credit system fallback
```

### T2.2 Fallback to Credit System
```
SETUP:   Customer has "gpt4_calls" with balance=0, "ai_credits" pool with balance=500
         Credit system: 1 gpt4_call = 10 credits
ACTION:  check(customer_id, feature_id="gpt4_calls", required_balance=5)
EXPECT:  { allowed: true } — 5 calls × 10 credits = 50 credits needed, 500 available
REASON:  Direct balance empty, falls back to credit system with conversion
```

### T2.3 Credit System Insufficient
```
SETUP:   Customer has "gpt4_calls" balance=0, "ai_credits" balance=30
         Credit system: 1 gpt4_call = 10 credits
ACTION:  check(customer_id, feature_id="gpt4_calls", required_balance=5)
EXPECT:  { allowed: false } — 5 × 10 = 50 needed, only 30 available
REASON:  Neither direct balance nor credit system has enough
```

### T2.4 Credit System Deduction After Track
```
SETUP:   "ai_credits" balance=100, 1 gpt4_call = 10 credits
ACTION:  track(customer_id, feature_id="gpt4_calls", value=3)
EXPECT:  "ai_credits" balance reduced to 70 (3 × 10 = 30 deducted)
REASON:  Track deducts from the credit system at the exchange rate
```

---

## T3: Product Check

### T3.1 Product Check — Active Subscription
```
SETUP:   Customer has product "pro_plan" with status=active
ACTION:  check(customer_id, product_id="pro_plan")
EXPECT:  { allowed: true, status: "active" }
```

### T3.2 Product Check — Canceled but Active Until Period End
```
SETUP:   Customer has "pro_plan", status=active, canceled_at=<timestamp>
ACTION:  check(customer_id, product_id="pro_plan")
EXPECT:  { allowed: true, status: "canceled" }
REASON:  Still active until period end, but status reflects cancellation intent
```

### T3.3 Product Check — Trial
```
SETUP:   Customer has "pro_plan", status=active, trial_ends_at=future_timestamp
ACTION:  check(customer_id, product_id="pro_plan")
EXPECT:  { allowed: true, status: "trialing" }
```

### T3.4 Product Check — Not Owned
```
SETUP:   Customer does NOT own "enterprise_plan"
ACTION:  check(customer_id, product_id="enterprise_plan")
EXPECT:  { allowed: false }
```

---

## T4: Overage Behaviors

### T4.1 Reject — Deny When Insufficient
```
SETUP:   "api_calls" balance=3, overage_behavior=reject
ACTION:  track(customer_id, feature_id="api_calls", value=5)
EXPECT:  Error: insufficient balance. Balance unchanged at 3.
REASON:  Reject is all-or-nothing — won't deduct partial
```

### T4.2 Cap — Deduct Available Only
```
SETUP:   "storage_mb" balance=3, overage_behavior=cap
ACTION:  track(customer_id, feature_id="storage_mb", value=5)
EXPECT:  Balance reduced to 0 (deducted 3, capped at 0). Returns { deducted: 3 }.
REASON:  Cap deducts what's available, never goes negative
```

### T4.3 Allow — Negative Balance
```
SETUP:   "compute_hours" balance=3, overage_behavior=allow
ACTION:  track(customer_id, feature_id="compute_hours", value=5)
EXPECT:  Balance reduced to -2. Overage of 2 hours billed on next invoice.
REASON:  Allow permits negative balance for arrear billing
```

### T4.4 Allow — Check Still Passes When Overage Allowed
```
SETUP:   "compute_hours" balance=0, overage_allowed=true, max_overage=100
ACTION:  check(customer_id, feature_id="compute_hours", required_balance=50)
EXPECT:  { allowed: true } — 0 remaining + 100 available overage >= 50 required
REASON:  Overage allowance extends the effective balance
```

---

## T5: Atomic Check + Track (send_event)

### T5.1 Concurrent Atomicity — The Gold Standard Test
```
SETUP:   "workflows" balance=5
ACTION:  7 concurrent check(customer_id, feature_id="workflows", send_event=true)
EXPECT:  Exactly 5 return allowed=true, exactly 2 return allowed=false
         Final balance = 0
REASON:  Atomic check+track prevents double-spending under concurrency
```

### T5.2 Send Event Deducts on Success
```
SETUP:   "messages" balance=10
ACTION:  check(customer_id, feature_id="messages", required_balance=3, send_event=true)
EXPECT:  { allowed: true, balance: { remaining: 7 } }
REASON:  send_event=true means the check itself deducted 3
```

### T5.3 Send Event Doesn't Deduct on Failure
```
SETUP:   "messages" balance=2
ACTION:  check(customer_id, feature_id="messages", required_balance=5, send_event=true)
EXPECT:  { allowed: false, balance: { remaining: 2 } }
REASON:  Insufficient balance — no deduction occurred
```

---

## T6: Idempotency

### T6.1 Duplicate Event Ignored
```
SETUP:   "api_calls" balance=100
ACTION:  track(customer_id, feature_id="api_calls", value=1, idempotency_key="evt_123")
         track(customer_id, feature_id="api_calls", value=1, idempotency_key="evt_123")  ← duplicate
EXPECT:  Balance = 99 (deducted once, not twice)
REASON:  Second call with same idempotency_key is a no-op
```

### T6.2 Different Keys Both Deduct
```
SETUP:   "api_calls" balance=100
ACTION:  track(..., value=1, idempotency_key="evt_123")
         track(..., value=1, idempotency_key="evt_456")
EXPECT:  Balance = 98 (two distinct events)
REASON:  Different keys = different events = both deducted
```

---

## T7: Entity-Level Gating

### T7.1 Entity-Scoped Check
```
SETUP:   Customer "acme" has 2 workspaces:
         workspace_1: api_calls balance=500
         workspace_2: api_calls balance=100
ACTION:  check(customer_id="acme", feature_id="api_calls", entity_id="workspace_2", required_balance=200)
EXPECT:  { allowed: false } — workspace_2 only has 100
REASON:  Entity check uses entity-specific balance, not customer-level
```

### T7.2 Entity-Scoped Track
```
SETUP:   workspace_1: api_calls balance=500
ACTION:  track(customer_id="acme", feature_id="api_calls", entity_id="workspace_1", value=50)
EXPECT:  workspace_1 balance = 450. workspace_2 balance unchanged.
REASON:  Track deducts from the specified entity only
```

### T7.3 Customer Check Without Entity Returns Customer-Level
```
SETUP:   Customer "acme" has customer-level "storage" balance=10GB
ACTION:  check(customer_id="acme", feature_id="storage")  ← no entity_id
EXPECT:  Uses customer-level balance (10GB), not entity-level
REASON:  Omitting entity_id falls back to customer scope
```

### T7.4 Entity Inherits Entitlements on Creation
```
SETUP:   Customer "acme" has "Pro" which grants 1000 api_calls per workspace
ACTION:  Create entity "workspace_3" for customer "acme"
EXPECT:  workspace_3 automatically has api_calls balance=1000
REASON:  Entity creation triggers entitlement initialization from product config
```

---

## T8: Entity Creation

### T8.1 Auto-Allocate on Entity Create
```
SETUP:   Product "Pro" grants 500 messages per entity
ACTION:  Create entity "user_1" for customer
EXPECT:  user_1.balances.messages = 500
```

### T8.2 Loose Entitlement on Entity
```
SETUP:   Customer "acme", entity "workspace_1" exists
ACTION:  Create loose entitlement: grant 500 messages to workspace_1
EXPECT:  check(customer_id="acme", feature_id="messages", entity_id="workspace_1")
         → allowed: true, balance.granted=500, balance.plan_id=null
REASON:  Loose entitlements (not tied to a product) should work at entity level
```

---

## T9: Reset Intervals

### T9.1 Monthly Reset at Cycle Boundary
```
SETUP:   "api_calls" balance=200 (of 1000), next_reset_at=March 15
ACTION:  Time advances past March 15. Next check triggers lazy reset.
EXPECT:  balance=1000, next_reset_at=April 15
REASON:  Monthly reset restores balance to granted amount
```

### T9.2 Custom Interval (Weekly)
```
SETUP:   "daily_exports" limit=10/week, next_reset_at=Monday
ACTION:  Time advances past Monday
EXPECT:  balance=10, next_reset_at=next Monday
```

### T9.3 Lazy Reset Before Check
```
SETUP:   "api_calls" next_reset_at was 2 hours ago, balance=0
ACTION:  check(customer_id, feature_id="api_calls")
EXPECT:  { allowed: true, balance: { remaining: 1000 } }
REASON:  Lazy reset fires inline before evaluating, even if cron hasn't run
```

---

## T10: Rollovers

### T10.1 Basic Rollover
```
SETUP:   "messages" balance=150 (of 400 granted), rollover_max=500
ACTION:  Cycle resets
EXPECT:  New balance = 400 (fresh grant). Rollover bucket = 150 (unused from last cycle).
         Effective total for checks = 400 + 150 = 550
```

### T10.2 Rollover Cap
```
SETUP:   "messages" balance=300 remaining, rollover_max=200
ACTION:  Cycle resets
EXPECT:  Rollover = 200 (capped), 100 unused units lost
```

### T10.3 Rollover Expiry
```
SETUP:   Rollover of 150 created with expiry=1 month. Time advances 1 month+1 day.
ACTION:  check(customer_id, feature_id="messages")
EXPECT:  Rollover expired — only current cycle balance available
```

### T10.4 Multiple Rollover Buckets
```
SETUP:   Cycle 1 rollover: 100 (expires March 1)
         Cycle 2 rollover: 200 (expires April 1)
         Current cycle balance: 400
ACTION:  check on Feb 15
EXPECT:  Effective balance = 400 + 100 + 200 = 700
ACTION:  check on March 15
EXPECT:  Effective balance = 400 + 200 = 600 (Cycle 1 rollover expired)
```

---

## T11: Loose Entitlement Expiry

### T11.1 Promotional Credits Expire
```
SETUP:   Loose entitlement: 500 bonus credits, expires_at=Dec 31
ACTION:  check on Jan 1
EXPECT:  { allowed: false } — credits expired
```

### T11.2 Promotional Credits Valid
```
SETUP:   Loose entitlement: 500 bonus credits, expires_at=Dec 31
ACTION:  check on Dec 30
EXPECT:  { allowed: true, balance.remaining: 500 }
```

---

## T12: Cancellation Impact on Entitlements

### T12.1 Cancel End-of-Cycle — Access Retained
```
SETUP:   Customer cancels Pro (cancel_at_period_end=true), period ends March 15
ACTION:  check on March 10
EXPECT:  { allowed: true } — still in paid period
```

### T12.2 Cancel End-of-Cycle — Access Revoked After Period
```
SETUP:   Same as T12.1
ACTION:  check on March 16 (after period end, subscription.deleted processed)
EXPECT:  { allowed: false } for Pro features, { allowed: true } for Free features
REASON:  Default product activated, Pro entitlements expired
```

### T12.3 Default Product Activation
```
SETUP:   Customer had Pro (api_calls=10000). Canceled. Period ended.
ACTION:  subscription.deleted handler activates default "Free" product
EXPECT:  check(feature_id="api_calls") → allowed: true, balance.granted=100 (free tier)
         check(feature_id="dashboard_access") → allowed: false (not in free tier)
REASON:  Customer drops to free, not zero
```

### T12.4 Immediate Cancellation
```
SETUP:   Customer cancels Pro with immediate deletion
ACTION:  subscription.deleted fires immediately
EXPECT:  Pro entitlements expired. Default product activated. Effective immediately.
```

---

## T13: Reactivation (Un-Cancel)

### T13.1 Reactivate Before Period End
```
SETUP:   Customer canceled Pro (cancel_at_period_end). Scheduled downgrade to Free at March 15.
ACTION:  Customer reactivates on March 10
EXPECT:  cancel_at_period_end=false. Scheduled default product removed.
         check on March 16 → still has Pro entitlements
REASON:  Reactivation clears the pending downgrade
```

### T13.2 Reactivation Restores Usage Balance
```
SETUP:   Customer had api_calls used=500 of 1000 when they canceled
ACTION:  Reactivate
EXPECT:  Balance stays at 500/1000 (no reset on reactivate)
REASON:  Reactivation doesn't reset the billing cycle
```

---

## T14: Past Due Status

### T14.1 Past Due — Access Maintained
```
SETUP:   Customer's payment fails. subscription.updated fires with status=past_due.
ACTION:  check(customer_id, feature_id="api_calls")
EXPECT:  { allowed: true }
REASON:  past_due grants access during grace period (Stripe retries payment)
```

### T14.2 Past Due — Auto-Cancel After Grace
```
SETUP:   Customer past_due for 30 days. Org config: cancel_on_past_due=true, grace_days=30.
ACTION:  Auto-cancel fires
EXPECT:  Subscription deleted. Default product activated. Pro access revoked.
```

---

## T15: Mid-Cycle Upgrade

### T15.1 Upgrade Resets Balances
```
SETUP:   Customer on Free (api_calls used 80 of 100). Upgrades to Pro (limit=10000).
ACTION:  upgrade_behavior=reset
EXPECT:  api_calls balance=10000, usage=0 (fresh start on Pro)
```

### T15.2 Upgrade Carries Over Usage
```
SETUP:   Same setup. upgrade_behavior=carry_over
EXPECT:  api_calls balance=9920 (10000 - 80 carried usage), usage=80
```

### T15.3 Upgrade Additive
```
SETUP:   Same setup. upgrade_behavior=additive
EXPECT:  api_calls balance=20 (remaining) + 10000 (new grant) = 10020
```

---

## T16: Trial Entitlements

### T16.1 Trial Grants Full Entitlements
```
SETUP:   Customer starts 14-day trial of Pro
EXPECT:  check(feature_id="api_calls") → allowed: true, balance.granted=10000
REASON:  Trial = full access to product's entitlements
```

### T16.2 Trial Ends — Payment Succeeds
```
SETUP:   Trial ends. Stripe charges successfully.
EXPECT:  Entitlements persist. Status changes from trialing to active.
REASON:  Seamless transition, no interruption
```

### T16.3 Trial Ends — Payment Fails
```
SETUP:   Trial ends. No payment method on file.
EXPECT:  Entitlements revoked. Default product activated.
REASON:  No payment = no access. Fall back to free tier.
```

### T16.4 Trial Usage Not Billed
```
SETUP:   Customer on trial uses 500 api_calls (usage-in-arrear billing)
ACTION:  invoice.created fires for first paid cycle
EXPECT:  Invoice does NOT include 500 trial usage. Only charges from paid period.
REASON:  Trial usage is free — trial_just_ended check skips arrear billing
```

---

## T17: Upgrade Preview

### T17.1 Usage Limit Scenario
```
SETUP:   Customer on Free, api_calls balance=0 (exhausted)
ACTION:  check(customer_id, feature_id="api_calls", with_preview=true)
EXPECT:  { allowed: false, preview: { 
            scenario: "usage_limit",
            title: "Upgrade to Pro",
            message: "You've reached the limit for API calls...",
            products: [{ id: "pro", name: "Pro", price: 29 }]
          }}
```

### T17.2 Feature Flag Scenario
```
SETUP:   Customer on Free, "dashboard_access" not in Free tier
ACTION:  check(customer_id, feature_id="dashboard_access", with_preview=true)
EXPECT:  { allowed: false, preview: {
            scenario: "feature_flag",
            title: "Upgrade to Pro",
            message: "Your plan does not include Dashboard Access..."
          }}
```

### T17.3 Add-On Available
```
SETUP:   Customer on Pro (api_calls exhausted). Add-on "Extra API Pack" available.
ACTION:  check with with_preview=true
EXPECT:  preview.products includes both upgrade (Enterprise) and add-on (Extra API Pack)
```

---

## T18: Client Integration

### T18.1 Publishable Key — Check Only
```
SETUP:   Client calls /check with publishable (public) API key
ACTION:  check(customer_id, feature_id="api_calls")
EXPECT:  Response returned (read-only). No tracking/deduction allowed.
```

### T18.2 Publishable Key — Track Rejected
```
SETUP:   Client calls /check with publishable key AND send_event=true
EXPECT:  Error: "Can't pass in 'send_event: true' when using publishable key"
REASON:  Public keys are read-only. Write operations require secret key.
```

---

## T19: Performance & Concurrency

### T19.1 Concurrent Track — Balance Never Goes Below Zero (Cap)
```
SETUP:   "messages" balance=5, overage_behavior=cap
ACTION:  5 concurrent track requests, each value=10
EXPECT:  Final balance = 0. Total deducted across all requests = 5.
REASON:  Cap behavior prevents negative balance even under concurrency
```

### T19.2 Cache Invalidation After Webhook
```
SETUP:   Customer cache has "Free" plan. Webhook arrives: subscription upgraded to "Pro".
ACTION:  Webhook processed. Cache invalidated.
EXPECT:  Next check returns Pro entitlements, not cached Free entitlements.
```

---

## T20: Failure Modes

### T20.1 Database Timeout — Default Deny
```
SETUP:   Database connection times out during check
EXPECT:  { allowed: false, reason: "check_error" }
REASON:  Default deny — never grant on failure
```

### T20.2 Webhook Handler Error — Still Return 200
```
SETUP:   invoice.paid handler throws an error
EXPECT:  Webhook endpoint returns HTTP 200 (prevent Stripe retries)
         Entitlement NOT granted (error state logged for investigation)
REASON:  Better to temporarily deny than to cause retry storms
```

---

## T21: Admin Balance Operations

### T21.1 Set Usage — Override Count
```
SETUP:   "api_calls" balance=700 (used 300 of 1000)
ACTION:  set_usage(customer_id, feature_id="api_calls", value=100)
EXPECT:  balance=900 (usage overridden to 100, so remaining = 1000 - 100)
REASON:  Customer support corrects an incorrect usage count
```

### T21.2 Update Balance — Add Credits
```
SETUP:   "ai_credits" balance=50
ACTION:  update_balance(customer_id, feature_id="ai_credits", delta=+200)
EXPECT:  balance=250
REASON:  Promotional grant or compensation for service disruption
```

### T21.3 Create Loose Entitlement
```
SETUP:   Customer has no "bonus_storage" entitlement
ACTION:  create_balance(customer_id, feature_id="bonus_storage", granted=50, expires_at=Dec_31)
EXPECT:  check(feature_id="bonus_storage") → allowed: true, balance=50, expires_at=Dec_31
REASON:  Grant a one-off entitlement not tied to any product
```

---

# SECTION C: Coverage Summary Checklist

After completing your implementation, verify coverage:

| Category | Tests | Pass? |
|---|---|---|
| **Feature Types** | T1.1–T1.5 | ☐ |
| **Credit Systems** | T2.1–T2.4 | ☐ |
| **Product Checks** | T3.1–T3.4 | ☐ |
| **Overage Behaviors** | T4.1–T4.4 | ☐ |
| **Atomic Check+Track** | T5.1–T5.3 | ☐ |
| **Idempotency** | T6.1–T6.2 | ☐ |
| **Entity-Level Gating** | T7.1–T7.4 | ☐ |
| **Entity Creation** | T8.1–T8.2 | ☐ |
| **Reset Intervals** | T9.1–T9.3 | ☐ |
| **Rollovers** | T10.1–T10.4 | ☐ |
| **Loose Entitlement Expiry** | T11.1–T11.2 | ☐ |
| **Cancellation Impact** | T12.1–T12.4 | ☐ |
| **Reactivation** | T13.1–T13.2 | ☐ |
| **Past Due** | T14.1–T14.2 | ☐ |
| **Mid-Cycle Upgrade** | T15.1–T15.3 | ☐ |
| **Trial Entitlements** | T16.1–T16.4 | ☐ |
| **Upgrade Preview** | T17.1–T17.3 | ☐ |
| **Client Integration** | T18.1–T18.2 | ☐ |
| **Performance** | T19.1–T19.2 | ☐ |
| **Failure Modes** | T20.1–T20.2 | ☐ |
| **Admin Operations** | T21.1–T21.3 | ☐ |

**Total: 21 categories, 56 test cases**

> If you scored YES on a Q&A question but the corresponding tests don't pass, your implementation has a gap. Go back to the feature-gating reference file for the implementation pattern.
