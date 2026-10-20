---
description: Interactive discovery to understand your billing requirements before writing any code. Detects your stack and guides you through pricing models, lifecycle rules, usage billing, credit systems, entity billing, and entitlement architecture.
argument-hint: [project-path]
---

# /billingplane:discover

## Purpose
Before implementing billing code, gather ALL requirements through structured discovery. This prevents rework and ensures edge cases are handled from day one.

## Instructions

### Phase 1: Stack Detection (automatic)
Examine project files to detect:
- Framework: `package.json` (Next.js, Express, Remix, SvelteKit), `requirements.txt` (Django, FastAPI), `go.mod`
- Database ORM: Prisma, Drizzle, SQLAlchemy, TypeORM, raw SQL
- Auth provider: NextAuth, Clerk, Supabase Auth, Better Auth, custom
- Existing Stripe packages and versions
- Existing billing code (check for `stripe` imports, webhook routes)

Report: "Detected: [framework] + [ORM] + [auth]. Stripe SDK: [version/none]. Existing billing code: [yes/no]."

If existing billing code found, suggest running `/billingplane:audit` first.

### Phase 2: Pricing Model
Ask sequentially. Wait for each answer.

1. **What are your pricing tiers?** (e.g., Free / Pro $29/mo / Enterprise custom)
2. **Billing frequency?** (Monthly, Yearly, Both with yearly discount, One-time purchase, Pay-as-you-go)
3. **Any usage-based components?** (API calls, storage, compute time, AI tokens, messages, seats)
4. **How should usage be billed?**
   - `in-arrear`: Track usage during cycle, bill at end (Autumn's `UsageInArrear`)
   - `in-advance`: Prepay for allocation, deduct as used (Autumn's `UsageInAdvance`)
   - `below-threshold`: Bill when usage drops below a prepaid threshold (Autumn's `UsageBelowThreshold`)
   - `fixed-cycle`: Fixed recurring regardless of usage (Autumn's `FixedCycle`)
   - `one-off`: Single charge per event (Autumn's `OneOff`)
5. **Do you need a credit/token system?** (Monetary credits, arbitrary tokens, AI credits that multiple features deduct from)
6. **Do you need trials?** (Duration, credit card required, what happens when trial ends without payment)
7. **Do you need coupons/promotional codes?** (Percentage off, fixed amount, duration, first-time only)

### Phase 3: Feature & Entitlement Architecture
8. **List every feature gated by plan.** For each feature, classify its type:
   - `boolean`: Access gate (has feature or doesn't) — Autumn's `FeatureType.Boolean`
   - `metered`: Tracked usage with limit (API calls, storage) — Autumn's `FeatureType.Metered`
   - `credit_system`: Deductible balance shared across features (AI tokens) — Autumn's `FeatureType.CreditSystem`
9. **For metered features: what are the limits per plan?** (e.g., Free=100 API calls/mo, Pro=10,000)
10. **What happens when a usage limit is hit?**
    - `cap`: Stop at zero, deny further usage
    - `reject`: Deny the request that would exceed the limit
    - `allow+bill`: Allow overage, bill for excess at end of cycle
    - `soft_warning`: Allow but show warning to user
11. **Do unused credits/usage roll over to the next cycle?** (Full rollover, partial, expire)
12. **What interval should usage reset on?** (Monthly aligned to billing cycle, weekly, daily, custom)

### Phase 4: Entity-Level Billing (if applicable)
13. **Do you bill per entity?** (Per team member/seat, per project, per workspace, per device)
14. **If seat-based: what are seat limits per plan?** (e.g., Pro=5 seats, Enterprise=unlimited)
15. **Can entities have independent usage limits?** (Each team member gets their own API quota)
16. **How does entity billing work?** (Flat per-seat price, or each seat also has usage-based charges)

### Phase 5: Lifecycle Rules
17. **What happens on upgrade?**
    - Immediate with proration (Stripe prorates, user pays difference now)
    - Deferred to end of cycle (Subscription Schedule, new plan starts next period)
    - Immediate access, bill at next cycle
18. **What happens on downgrade?**
    - End of current period (keep current plan until cycle ends)
    - Immediate with credit (Stripe credits unused time)
    - Immediate, lose access to premium features now
19. **What happens on cancellation?**
    - `cancel_at_period_end`: Keep access until cycle ends, then fall to default plan
    - Immediate: Revoke access now
    - `cancel_at` specific date: Custom cancellation date
20. **What should the default/fallback plan be?** When paid plan ends, does user get a free tier or lose all access?
21. **Can users reactivate after canceling?** (Un-cancel before period ends, or re-subscribe)
22. **Grace period for failed payments?** (Days before revoking access, auto-cancel on past_due?)
23. **Do you need pause/resume?** (Temporary subscription hold)

### Phase 6: Infrastructure & Operations
24. **Existing Stripe account?** (Test/live keys ready, existing products/prices in Stripe?)
25. **Where will webhooks be received?** (Same app server, serverless function, separate microservice)
26. **Need Stripe Customer Portal?** (Self-service plan management, payment method updates)
27. **Need email notifications?** (Payment receipts, trial ending, payment failed, subscription changes)
28. **Need admin dashboard?** (Manual sync, customer support tools, revenue analytics)
29. **Expected scale?** (Affects caching strategy: <1K customers=DB-only, 1K-50K=Redis cache, 50K+=Redis+CDN)
30. **Multi-currency or international tax?** (Stripe Tax, VAT handling, currency conversion)

### Output
Generate `BILLING_REQUIREMENTS.md` with ALL collected information:

```markdown
# Billing Requirements — [Project Name]

## Stack
- Framework: ...
- ORM: ...
- Auth: ...
- Stripe SDK: ...

## Pricing Architecture
| Tier | Monthly | Yearly | Billing Type |
|------|---------|--------|-------------|
| Free | $0 | - | - |
| Pro | $X | $Y | fixed_cycle |
| Enterprise | Custom | Custom | fixed_cycle + usage_in_arrear |

## Feature Entitlements
| Feature | Type | Free | Pro | Enterprise |
|---------|------|------|-----|------------|
| Dashboard | boolean | ✅ | ✅ | ✅ |
| API calls | metered | 100/mo | 10K/mo | unlimited |
| AI tokens | credit_system | 0 | 1000/mo | 10000/mo |

## Usage Configuration
| Feature | Billing Model | Overage | Reset Interval | Rollover |
|---------|--------------|---------|----------------|----------|
| API calls | in_arrear | cap | monthly (billing anchor) | none |
| AI tokens | credit_system | allow+bill | monthly | partial (50%) |

## Entity Billing
- Entity type: [team_members / projects / none]
- Seat limits: Free=1, Pro=5, Enterprise=unlimited
- Per-entity usage: [yes/no]

## Lifecycle Rules
- Upgrade: [immediate_prorate / end_of_cycle_schedule / immediate_no_prorate]
- Downgrade: [end_of_period / immediate_credit]
- Cancellation: [cancel_at_period_end / immediate]
- Default fallback plan: [free_tier / no_access]
- Reactivation: [allowed / not_allowed]
- Failed payment grace period: [X days / auto_cancel_on_past_due]
- Trial: [X days, card_required: yes/no, on_expire: cancel/downgrade_to_free]

## Infrastructure
- Webhook target: [same_app / serverless / microservice]
- Customer portal: [yes/no]
- Caching strategy: [db_only / redis / redis+cdn]
- Multi-currency: [yes/no]
- Tax handling: [stripe_tax / manual / none]

## Implementation Plan
1. Environment setup + env vars
2. Database schema (users, subscriptions, customer_entitlements, webhook_events, usage_events)
3. Stripe config map (price IDs from env vars)
4. Server-only Stripe client
5. Checkout session endpoint
6. Webhook handler (all required events)
7. Entitlement engine (check + track endpoints)
8. Feature gating middleware
9. Usage tracking + arrear billing (if applicable)
10. Credit system (if applicable)
11. Subscription management (upgrade/downgrade/cancel)
12. Customer portal
13. Success/cancel pages (poll-based, never trust redirect)
14. Trial management (if applicable)
15. Default product fallback
16. Admin sync endpoint
17. Cache layer (if scale requires)
18. Validation via /billingplane:audit

## Required Environment Variables
- STRIPE_SECRET_KEY (server-only)
- STRIPE_WEBHOOK_SECRET
- NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY (client-safe)
- STRIPE_PRICE_[TIER]_[FREQUENCY] (one per price)
- REDIS_URL (if caching enabled)
```

Save to project root as `BILLING_REQUIREMENTS.md`.
