# Feature Gating & Entitlement Engine — Complete Reference

> The entitlement engine is the runtime heart of your billing system.
> Every API call, every page load, every feature toggle ultimately asks one question:
> **"Is this customer allowed to do this thing right now?"**

---

## Architecture Overview

Feature gating is NOT just "check if user has plan X." A production entitlement engine handles:

1. **Feature checks** — Does the customer have access to feature Y with sufficient balance?
2. **Product checks** — Does the customer own product X (regardless of which features it grants)?
3. **Usage tracking** — Atomically deduct from a balance when a feature is consumed
4. **Credit systems** — Shared token pools that multiple features draw from at different rates
5. **Entity-level gating** — Per-seat, per-workspace, per-project independent limits
6. **Overage handling** — What happens when limits are exceeded (cap, reject, allow+bill)
7. **Balance lifecycle** — Resets, rollovers, expiry, lazy evaluation, caching
8. **Upgrade previews** — When denied, show what the customer should buy next

---

## 1. Feature Types

Every gated feature falls into one of three types. Classify them correctly before writing any code.

### Boolean Features
Access gate — customer either has the feature or doesn't. No balance, no tracking.

```
Examples: Dashboard access, Advanced analytics, SSO, Custom branding
Check logic: entitlement exists for active product → allowed
```

### Metered Features
Tracked usage with a numeric limit that resets on a cycle.

```
Examples: API calls (1000/mo), Storage (10GB), Team members (5 seats)
Check logic: remaining_balance >= required_amount → allowed
Track logic: atomically deduct required_amount from balance
Reset logic: balance → granted amount at cycle boundary
```

### Credit System Features
A shared numeric pool that multiple features deduct from at different exchange rates.

```
Examples: AI tokens (GPT-4 = 10 credits, GPT-3.5 = 1 credit), Platform credits ($50/mo pool)
Check logic: 
  1. Try direct feature balance first
  2. If insufficient, find credit systems containing this feature
  3. Convert required_amount to credit cost using exchange rate
  4. Check if credit system balance >= converted cost
Track logic: deduct converted cost from credit system balance
```

**Credit System Schema Definition:**
```typescript
// Each credit system defines exchange rates per feature
interface CreditSystemConfig {
  schema: Array<{
    metered_feature_id: string;  // e.g., "gpt4_calls"
    feature_amount: number;       // e.g., 1 (1 call)
    credit_amount: number;        // e.g., 10 (costs 10 credits)
  }>;
}

// Conversion: credits_needed = (credit_amount / feature_amount) * requested_units
// Example: 5 GPT-4 calls = (10/1) * 5 = 50 credits
```

---

## 2. The Check Endpoint

The check endpoint is the single point of truth for "is this allowed?" It must handle ALL feature types, entity scoping, credit fallback, and balance evaluation in one call.

### Request Shape
```typescript
interface CheckRequest {
  customer_id: string;
  feature_id?: string;       // For feature-level check
  product_id?: string;       // For product-level check (legacy/simple)
  entity_id?: string;        // For entity-scoped check (per-seat, per-workspace)
  required_balance?: number; // How much balance is needed (default: 1)
  send_event?: boolean;      // Atomic check + track in one call
  with_preview?: boolean;    // Return upgrade suggestions if denied
}
```

### Response Shape
```typescript
interface CheckResponse {
  allowed: boolean;
  customer_id: string;
  entity_id?: string;
  required_balance: number;
  balance: {
    feature_id: string;
    granted: number;          // Total allocated for this cycle
    remaining: number;        // Current available balance
    usage: number;            // Amount consumed this cycle
    unlimited: boolean;       // Unlimited access flag
    overage_allowed: boolean; // Can exceed limit
    next_reset_at: number | null;  // When balance resets
    breakdown: BalanceBreakdown[];  // Per-entitlement detail
  } | null;
  preview?: UpgradePreview;  // Only if with_preview=true and allowed=false
}
```

### Check Logic Flow

```
CHECK(customer_id, feature_id, required_balance, entity_id?)
│
├─ 1. Resolve customer (cache → DB → create if auto-create enabled)
│
├─ 2. If entity_id provided:
│     └─ Filter customer_products to entity-specific ones
│     └─ Compute balances scoped to entity
│
├─ 3. Determine feature type:
│     ├─ Boolean → entitlement exists for active product? → allowed: true
│     ├─ Metered → check balance (see step 4)
│     └─ CreditSystem → check balance (see step 4)
│
├─ 4. Find the "feature to use" for balance check:
│     ├─ Try direct feature balance first
│     │   └─ If allowed with direct balance → use direct feature
│     ├─ If not allowed OR no direct balance → check credit systems
│     │   └─ For each credit system containing this feature:
│     │       └─ Convert required_balance to credit cost
│     │       └─ If credit system balance >= converted cost → use credit system
│     └─ If no credit system works → use first credit system (will fail)
│
├─ 5. Evaluate allowed:
│     ├─ No balance object at all → allowed: false
│     ├─ Boolean feature → allowed: true (existence = access)
│     ├─ Unlimited flag → allowed: true
│     ├─ required_balance < 0 → allowed: true (granting, not consuming)
│     ├─ Overage allowed + available overage exists:
│     │   └─ remaining + available_overage >= required_balance → allowed
│     ├─ remaining >= required_balance → allowed: true
│     └─ Otherwise → allowed: false
│
├─ 6. If with_preview and NOT allowed:
│     └─ Find products that would grant this feature
│     └─ Filter to upgrades from current plan + relevant add-ons
│     └─ Return upgrade suggestion with product details
│
└─ 7. Return response
```

### Lazy Reset (Critical Pattern)

Before evaluating balance, check if a reset is overdue:

```typescript
async function checkWithLazyReset(customerId: string, featureId: string, entityId?: string) {
  const entitlement = await getEntitlement(customerId, featureId, entityId);
  
  if (entitlement.next_reset_at && entitlement.next_reset_at <= Date.now()) {
    // Reset is overdue — do it inline before checking
    await resetEntitlement(entitlement);
    // Re-fetch after reset
    return await getEntitlement(customerId, featureId, entityId);
  }
  
  return entitlement;
}
```

This prevents stale balances when the cron job hasn't run yet. Both cron AND lazy reset should exist — cron for bulk efficiency, lazy for correctness.

---

## 3. Product Check (Simple Mode)

For apps that only need "does customer own product X?" without feature-level granularity:

```typescript
async function checkProduct(customerId: string, productId: string, entityId?: string) {
  const cusProducts = await getCustomerProducts(customerId, entityId);
  
  const match = cusProducts.find(cp => cp.product_id === productId);
  
  if (!match) {
    return { allowed: false, status: null };
  }
  
  const onTrial = match.trial_ends_at && match.trial_ends_at > Date.now();
  
  return {
    allowed: match.status === 'active' || match.status === 'past_due',
    status: match.canceled_at ? 'canceled' 
           : onTrial ? 'trialing' 
           : match.status,
  };
}
```

Key: `past_due` still grants access (grace period). `canceled` with `cancel_at_period_end` still has `status: active` until period ends. The `canceled` status in the response indicates intent, not immediate revocation.

---

## 4. Atomic Check + Track (send_event)

**The Race Condition Problem:**
```
Thread A: check(feature=api_calls, required=1)  → allowed: true (balance=1)
Thread B: check(feature=api_calls, required=1)  → allowed: true (balance=1)
Thread A: track(feature=api_calls, value=1)      → balance=0
Thread B: track(feature=api_calls, value=1)      → balance=-1  ← VIOLATION
```

**The Solution: Atomic Check + Track**

When `send_event: true`, the check endpoint atomically checks AND deducts in one operation. If the deduction fails (insufficient balance), it returns `allowed: false` without modifying state.

```typescript
async function checkWithTrack(customerId: string, featureId: string, requiredBalance: number) {
  try {
    // Attempt atomic deduction — this is the check AND the track
    const result = await atomicDeduct(customerId, featureId, requiredBalance, {
      overage_behavior: 'reject',  // Fail if insufficient
    });
    
    return { allowed: true, balance: result.newBalance };
  } catch (error) {
    if (error instanceof InsufficientBalanceError) {
      return { allowed: false, balance: error.currentBalance };
    }
    throw error;
  }
}
```

**Concurrency test expectation (from Autumn):**
```
Setup: feature with balance = 5
Action: 7 concurrent check+track requests (send_event=true)
Expected: exactly 5 allowed, exactly 2 denied
```

This is the gold standard test for atomic gating. If your system allows 6 or 7, your atomicity is broken.

---

## 5. Usage Tracking (Track Endpoint)

### Request Shape
```typescript
interface TrackRequest {
  customer_id: string;
  feature_id: string;
  entity_id?: string;
  value: number;               // Amount to deduct (positive) or grant (negative)
  idempotency_key?: string;    // Prevent double-counting
  overage_behavior?: 'cap' | 'reject' | 'allow';
  properties?: Record<string, any>;  // Event metadata
}
```

### Atomic Deduction Patterns

**Option A: Database Transaction (Postgres)**
```sql
BEGIN;
SELECT balance FROM customer_entitlements 
  WHERE customer_id = $1 AND feature_id = $2
  FOR UPDATE;  -- Row lock prevents concurrent reads

-- Check balance >= required (for 'reject' behavior)
-- Or cap deduction at available balance (for 'cap' behavior)

UPDATE customer_entitlements 
  SET balance = balance - $3
  WHERE customer_id = $1 AND feature_id = $2;
COMMIT;
```

**Option B: Redis Lua Script (High-throughput)**
```lua
local key = KEYS[1]
local deduct = tonumber(ARGV[1])
local min_balance = tonumber(ARGV[2])  -- 0 for cap, -inf for allow

local current = tonumber(redis.call('GET', key) or '0')
local new_balance = current - deduct

if new_balance < min_balance then
  return {0, current}  -- Rejected
end

redis.call('SET', key, tostring(new_balance))
return {1, new_balance}  -- Success
```

### Overage Behavior Matrix

| Behavior | When balance < required | Use Case |
|----------|------------------------|----------|
| `cap` | Deduct only what's available, stop at 0 | Storage, seats (graceful degradation) |
| `reject` | Deny the entire request, deduct nothing | API calls, transactions (all-or-nothing) |
| `allow` | Allow negative balance, bill overage in arrear | Usage-based pricing (meter everything, bill later) |

### Idempotency
```typescript
// Before deducting, check if this event was already processed
const existing = await db.usageEvents.findUnique({
  where: { idempotency_key: request.idempotency_key }
});

if (existing) {
  return { already_processed: true, balance: currentBalance };
}

// Process deduction, then record event
await db.usageEvents.create({
  idempotency_key: request.idempotency_key,
  customer_id, feature_id, value, 
  created_at: Date.now(),
});
```

---

## 6. Entity-Level Gating

Entities are sub-resources of a customer with independent entitlements: workspaces, team members, projects, devices.

### Entity Data Model
```typescript
interface Entity {
  id: string;              // "workspace_abc123"
  customer_id: string;
  name: string;
  feature_id: string;      // Which feature tracks entities (e.g., "seats")
  created_at: number;
}

// Entitlement balance is stored per-entity
interface CustomerEntitlement {
  // ... base fields ...
  entities: Record<string, EntityBalance> | null;
}

interface EntityBalance {
  id: string;       // entity_id
  balance: number;
  adjustment: number;
  additional_balance?: number;
}
```

### Entity Check Flow
```
CHECK(customer_id="acme", feature_id="api_calls", entity_id="workspace_1")
│
├─ 1. Get customer with entities
├─ 2. Filter customer_products to those belonging to entity "workspace_1"
├─ 3. Compute balances from entity-filtered products
├─ 4. Check entity-specific balance for "api_calls"
└─ 5. Return entity-scoped result
```

### Entity-Scoped Track
When tracking usage with an entity_id, deduct from the entity's balance within the entitlement, NOT the customer-level balance:

```typescript
// Entity balance lives inside the entitlement's entities map
entitlement.entities["workspace_1"].balance -= deductAmount;
```

---

## 7. Balance Lifecycle

### Initialization (Product Attached)
When a customer subscribes to a product:

```typescript
function initEntitlement(entitlement, product) {
  // Boolean → balance irrelevant (access is binary)
  if (isBoolean(entitlement)) return { balance: 0, unlimited: null };
  
  // Unlimited → balance irrelevant
  if (isUnlimited(entitlement)) return { balance: 0, unlimited: true };
  
  // Metered → starting balance = included_usage × quantity
  const startingBalance = getStartingBalance(entitlement, quantity);
  
  // Entity-scoped → distribute balance across entities
  const entities = isEntityScoped(entitlement) 
    ? distributeToEntities(customer.entities, startingBalance)
    : null;
  
  return {
    balance: startingBalance,
    unlimited: false,
    usage_allowed: isArrearBilling(entitlement),  // Arrear features allow usage beyond balance
    next_reset_at: calculateNextReset(entitlement, subscription),
    entities,
  };
}
```

### Reset (Cycle Boundary)
At each billing cycle boundary, metered features reset:

```typescript
async function resetEntitlement(cusEnt) {
  const newBalance = cusEnt.entitlement.included_usage;
  const nextResetAt = calculateNextReset(cusEnt.next_reset_at, interval);
  
  // Handle rollovers BEFORE resetting
  if (cusEnt.entitlement.rollover && cusEnt.balance > 0) {
    const rolloverAmount = Math.min(cusEnt.balance, cusEnt.entitlement.rollover.max);
    await createRollover(cusEnt, rolloverAmount, nextResetAt);
  }
  
  await db.customerEntitlements.update({
    where: { id: cusEnt.id },
    data: {
      balance: newBalance,
      next_reset_at: nextResetAt,
    },
  });
}
```

### Rollover Rules
| Config | Behavior |
|--------|----------|
| `max: 500` | Carry over up to 500 unused units to next cycle |
| `duration: { length: 1, type: 'month' }` | Rolled-over balance expires after 1 month |
| No rollover config | Unused balance is lost at reset |

### Expiry (Loose Entitlements)
Entitlements without a reset interval (one-time grants, promotional credits) can have an `expires_at` timestamp:

```typescript
function checkLooseEntitlement(cusEnt) {
  if (cusEnt.expires_at && cusEnt.expires_at <= Date.now()) {
    // Expired — treat as zero balance
    return { allowed: false, reason: 'expired' };
  }
  return { allowed: cusEnt.balance >= requiredBalance };
}
```

---

## 8. Upgrade Preview (Denied Check)

When a check returns `allowed: false` and `with_preview: true`, return actionable upgrade suggestions:

```typescript
async function getCheckPreview(feature, customer) {
  // Find all products that grant this feature
  const products = await getProductsByFeature(feature.id);
  
  // Determine scenario
  const scenario = customer.hasAnyBalance(feature.id) 
    ? 'usage_limit'      // Has feature, ran out
    : 'feature_flag';    // Doesn't have feature at all
  
  // Filter to upgrades (higher tier) and relevant add-ons
  const upgrades = products.filter(p => !p.is_add_on && isUpgrade(p, customer.currentPlan));
  const addOns = products.filter(p => p.is_add_on && !customer.owns(p.id));
  
  return {
    scenario,              // 'usage_limit' or 'feature_flag'
    title: `Upgrade to ${upgrades[0]?.name}`,
    message: scenario === 'usage_limit'
      ? `You've reached the limit for ${feature.name}. Upgrade to continue.`
      : `${feature.name} is not available on your plan.`,
    products: [...upgrades, ...addOns],  // With pricing details
    upgrade_product_id: upgrades[0]?.id || addOns[0]?.id,
  };
}
```

This powers client-side upgrade prompts — the frontend calls check, gets `allowed: false` with a preview, and renders an upgrade modal with zero additional API calls.

---

## 9. Caching Strategy

### Cache Layers
```
Request → Redis Cache (TTL ~60s) → Database → Compute
                ↓ miss                  ↓ miss
          Cached FullCustomer     Fresh FullCustomer
```

### Cache Invalidation Triggers
- Webhook processed (subscription change, payment, cancellation)
- Track/deduct endpoint called
- Manual balance update
- Entitlement reset

### Cache-Aside Pattern
```typescript
async function getCustomerForCheck(customerId: string) {
  // 1. Try Redis cache
  const cached = await redis.get(`customer:${customerId}`);
  if (cached) return JSON.parse(cached);
  
  // 2. Fetch from DB
  const customer = await db.getFullCustomer(customerId);
  
  // 3. Store in cache
  await redis.set(`customer:${customerId}`, JSON.stringify(customer), 'EX', 60);
  
  return customer;
}

// After ANY mutation:
async function invalidateCustomerCache(customerId: string) {
  await redis.del(`customer:${customerId}`);
}
```

---

## 10. Server-Side Middleware

### Express/Hono Middleware
```typescript
function requireFeature(featureId: string, requiredBalance: number = 1) {
  return async (req, res, next) => {
    const customerId = req.auth.customerId;
    const entityId = req.headers['x-entity-id'];  // Optional entity scope
    
    const result = await checkEntitlement(customerId, featureId, requiredBalance, entityId);
    
    if (!result.allowed) {
      return res.status(403).json({
        error: 'feature_limit_exceeded',
        feature_id: featureId,
        balance: result.balance,
        preview: result.preview,  // Upgrade suggestions
      });
    }
    
    // Attach to request for downstream handlers
    req.entitlement = result;
    next();
  };
}

// Usage:
app.post('/api/generate', requireFeature('ai_generations'), handler);
app.post('/api/members', requireFeature('team_members'), handler);
```

### Check-Then-Track Pattern
```typescript
app.post('/api/generate', requireFeature('ai_tokens', 10), async (req, res) => {
  // Feature check already passed via middleware
  
  // Do the expensive work
  const result = await generateContent(req.body);
  
  // Track actual usage (may differ from required)
  const actualTokens = result.tokensUsed;
  await trackUsage(req.auth.customerId, 'ai_tokens', actualTokens, {
    idempotency_key: req.id,
  });
  
  res.json(result);
});
```

### Atomic Check+Track Pattern (Preferred for countable resources)
```typescript
app.post('/api/send-message', async (req, res) => {
  const result = await checkWithTrack(req.auth.customerId, 'messages', 1);
  
  if (!result.allowed) {
    return res.status(403).json({
      error: 'limit_exceeded',
      ...result.preview,
    });
  }
  
  // Proceed — deduction already happened atomically
  const message = await sendMessage(req.body);
  res.json(message);
});
```

---

## 11. Default Deny Principle

**When in doubt, deny.** The entitlement engine must fail closed:

```typescript
async function checkEntitlement(customerId, featureId, required, entityId) {
  try {
    return await performCheck(customerId, featureId, required, entityId);
  } catch (error) {
    logger.error('Entitlement check failed', { customerId, featureId, error });
    
    // DEFAULT DENY — never grant access on error
    return { allowed: false, reason: 'check_error' };
  }
}
```

Exceptions: Webhook handlers should return 200 even on error (to prevent Stripe retries that could cause loops). But the entitlement write should be skipped — better to have a customer temporarily locked out than to grant access they haven't paid for.

---

## 12. Decimal Precision

**Never use floating-point arithmetic for balance computations.**

```typescript
// WRONG — floating point drift
const remaining = 0.1 + 0.2;  // 0.30000000000000004

// CORRECT — use Decimal.js or integer math
import { Decimal } from 'decimal.js';
const remaining = new Decimal(apiBalance.remaining).gte(requiredBalance);

// OR: store everything as integers (cents, millicredits)
const balanceMicro = 100_000;  // 100.000 credits
const costMicro = 10_500;      // 10.500 credits
const remaining = balanceMicro - costMicro;  // 89_500
```

---

## 13. Common Mistakes

1. **Checking plan name instead of entitlements**: `if (user.plan === 'pro')` breaks when you add plans, rename them, or grant features via add-ons. Always check the feature/entitlement, not the plan.

2. **Client-side gating only**: A frontend check is a UI hint. The server must enforce access. An attacker can bypass any client-side gate.

3. **Check and track as separate non-atomic calls**: The race condition between check and track is real. Use atomic check+track for countable resources.

4. **Forgetting entity scope**: If your app has workspaces/teams, a customer-level check passes but the entity-level check may fail (entity has its own limits).

5. **No lazy reset**: If the cron job is late or misses a cycle, customers see stale balances. Always check `next_reset_at` before evaluating.

6. **Ignoring credit system fallback**: A feature check fails because the direct balance is 0, but the customer has 500 credits in their credit pool that maps to this feature. Without fallback, you wrongly deny.

7. **No default product after cancellation**: Customer cancels Pro → subscription.deleted fires → entitlements expire → customer has NO entitlements → every check fails → even free-tier features are locked. Always activate a default/free product.

8. **Granting access from checkout redirect**: Checkout completes → redirect to app → app reads URL param `?plan=pro` → grants access before webhook arrives. The webhook is the source of truth, not the redirect.
