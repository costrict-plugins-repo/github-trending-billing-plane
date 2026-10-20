---
description: Billing model decision framework for SaaS applications. Auto-activates when discussing usage-based pricing, seat-based billing, credit systems, hybrid pricing, freemium models, billing architecture, or build-vs-buy decisions.
keywords: usage-based pricing, seat-based billing, credits, credit system, hybrid pricing, freemium, build-vs-buy, billing architecture, metering, overage, arrear billing
---

# Billing Pattern Decisions

## Six Billing Types (from production billing systems)

| Type | Model | Complexity | Example |
|------|-------|-----------|---------|
| Fixed Cycle | Flat recurring charge | Low | $29/month subscription |
| One-Off | Single charge | Low | Lifetime license, add-on purchase |
| Usage In-Arrear | Track usage, bill at cycle end | High | API calls billed per-request |
| Usage In-Advance | Prepay for allocation | Medium | Buy 10,000 API calls upfront |
| Below Threshold | Auto-top-up when balance drops | Medium | Credit balance auto-recharge |
| In-Arrear Prorated | Arrear billing with mid-cycle changes | High | Seat-based with mid-cycle additions |

## Feature Types

| Type | How It Works | Stripe Mechanism |
|------|-------------|-----------------|
| Boolean | Access gate (yes/no) | Product/plan membership |
| Metered | Tracked balance with limits | Usage records or custom tracking |
| Credit System | Shared deductible pool | Custom tracking (Stripe doesn't natively support) |

## Build-vs-Buy Framework

| Approach | Best For | Trade-off |
|----------|----------|-----------|
| **BillingPlane** (this tool) | Full control, zero runtime dependency | Knowledge stays in codebase, more upfront work |
| **Autumn** | Fast setup, complex billing handled | Runtime dependency, vendor lock-in, abstracts Stripe |
| **Self-host Autumn** | Complex billing + full control | DevOps overhead, must maintain infrastructure |
| **Raw Stripe** | Simple billing, deep customization | Every edge case is your problem |

The wrong answer is building without guardrails OR buying without understanding what the middleware does.

## Pricing Model Selection Guide

**Start with Fixed Cycle** if: your product has clear tier boundaries and usage is similar across customers in a tier.

**Add Usage-In-Arrear** if: customer value scales with usage (API platforms, AI tools, infrastructure).

**Add Credit System** if: multiple features share a common value unit (AI tokens used by chat, image gen, analysis).

**Add Seat-Based** if: billing scales with team size (B2B SaaS, collaboration tools).

**Use Subscription Schedules** if: upgrades/downgrades should take effect at billing period boundaries rather than immediately.

## Overage Handling Decision

| Strategy | User Experience | Revenue Impact | Implementation |
|----------|----------------|----------------|----------------|
| Hard cap | Blocked at limit | Lost usage, but predictable | Simplest: check balance before allowing |
| Soft cap + warning | Warned but allowed | Better retention, unpredictable cost | Check balance, warn at threshold |
| Allow + bill overage | Never blocked | Maximum revenue, billing complexity | Track negative balance, bill in arrear |
| Auto-upgrade | Pushed to next tier | Good conversion, user surprise risk | Trigger upgrade flow at limit |
