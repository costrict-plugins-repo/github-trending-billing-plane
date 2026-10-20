# BillingPlane

**Guardrails-first Stripe billing for Claude Code.** Audit, discover, implement, and validate with zero runtime dependencies.

## What Does BillingPlane Do?

BillingPlane is a Claude Code plugin that ensures every Stripe billing integration follows battle-tested guardrails extracted from production billing systems. It catches revenue-losing bugs before they ship.

Unlike billing middleware (Autumn, Lago, Schematic), BillingPlane generates code **you own**. No runtime dependency. No vendor lock-in. No ongoing fees.

### What It Covers (4,000+ lines of billing intelligence)

**4 Slash Commands:**

- `/billingplane:audit` — Deep-scan your codebase for billing violations across 8 categories. Produces a severity-ranked report with exact file locations and fixes.
- `/billingplane:discover` — Interactive requirements gathering (30 questions). Outputs BILLING_REQUIREMENTS.md.
- `/billingplane:implement` — Generates production-ready billing code from requirements. 18 steps covering schema, webhooks, entitlements, usage, credits, trials, lifecycle.
- `/billingplane:feature-gating-requirements` — 21 Q&A questions + 56 test cases for entitlement validation.

**2 Auto-Activating Skills:**

- `stripe-billing` — 15 guardrail rules auto-activate when Claude works with Stripe code. 7 reference files.
- `billing-patterns` — Pricing model selection guide, build-vs-buy framework.

**1 Webhook Validator Agent + 1 Pre-Write Safety Hook**

### Key Patterns

| Area | Coverage |
|---|---|
| Webhooks | 12 events, 6-layer middleware, idempotency, signature verification |
| Lifecycle | 3 cancellation variants, reactivation, past_due, default fallback, trials, upgrades |
| Feature gating | Boolean/metered/credit features, atomic check+track, entity-level, overage, preview |
| Usage billing | 6 billing types, invoice.created handler, final invoice, balance reset |
| Entitlements | Lazy reset, rollover, expiry, Decimal.js precision, default deny |
| Concurrency | Subscription locks, cache invalidation, Redis Lua, SELECT FOR UPDATE |

---

## Installation

### From GitHub
```bash
/plugin marketplace add kamesh231/billingplane-marketplace
/plugin install billingplane@kamesh231
```

### Local Development
```bash
git clone https://github.com/kamesh231/billingplane.git
claude --plugin-dir ./billingplane
```

### Team Setup
Add to `.claude/settings.json`:
```json
{
  "plugins": {
    "marketplaces": ["kamesh231/billingplane-marketplace"],
    "autoInstall": ["billingplane@kamesh231"]
  }
}
```

---

## Usage

```bash
/billingplane:audit src/          # Scan for violations
/billingplane:discover            # Gather requirements
/billingplane:implement           # Generate code
/billingplane:feature-gating-requirements  # Validate entitlements
```

Skills auto-activate when Claude detects Stripe-related work.

---

## Publishing

1. Push to GitHub
2. Create a marketplace repo with `.claude-plugin/marketplace.json`
3. Submit to community lists (ccplugins/awesome-claude-code-plugins)

## The 15 Rules

1. Never hardcode prices
2. Secret key server-side only
3. Frontend: publishable key + Price IDs only
4. All state changes via webhooks
5. Redirects never imply payment success
6. Feature access never from UI state
7. Webhook signature verification mandatory
8. Idempotency per event ID
9. subscription.updated MUST inspect previous_attributes
10. Default DENY on ambiguity
11. Never compute money client-side
12. Always schedule default product on cancellation
13. Webhook handler always returns 200
14. Usage billing requires invoice.created handler
15. Atomic entitlement deductions

## License

MIT
