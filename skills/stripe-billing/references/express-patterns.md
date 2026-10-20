# Express / Node.js — Stripe Billing Patterns

## Critical: Raw Body Middleware for Webhooks

```javascript
const express = require('express');
const app = express();

// IMPORTANT: Webhook route MUST use raw body (before json parser)
app.post('/api/stripe/webhook', 
  express.raw({ type: 'application/json' }),
  handleWebhook
);

// JSON parser for all other routes
app.use(express.json());
```

## Stripe Client Setup

```typescript
// lib/stripe.ts
import Stripe from 'stripe';

if (!process.env.STRIPE_SECRET_KEY) {
  throw new Error('STRIPE_SECRET_KEY is not set');
}

export const stripe = new Stripe(process.env.STRIPE_SECRET_KEY, {
  apiVersion: '2024-12-18.acacia',
});
```

## Checkout Endpoint

```typescript
app.post('/api/checkout', authenticate, async (req, res) => {
  const { priceId } = req.body;
  
  // Validate price against allowlist
  const allowedPrices = (process.env.STRIPE_ALLOWED_PRICES || '').split(',');
  if (!allowedPrices.includes(priceId)) {
    return res.status(400).json({ error: 'Invalid price ID' });
  }

  const customerId = await getOrCreateCustomer(req.user);

  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    mode: 'subscription',
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: `${process.env.APP_URL}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${process.env.APP_URL}/pricing`,
    metadata: { userId: req.user.id },
  });

  res.json({ url: session.url });
});
```

## Webhook Handler

```typescript
async function handleWebhook(req, res) {
  const sig = req.headers['stripe-signature'];
  
  let event;
  try {
    event = stripe.webhooks.constructEvent(
      req.body, // raw body from express.raw()
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  // Always respond 200 quickly, process async
  res.json({ received: true });
  
  // Process in background (don't block the response)
  processWebhookEvent(event).catch(err => {
    console.error('Error processing webhook:', err);
  });
}
```

## Entitlements Middleware

```typescript
function requirePlan(requiredPlan: string) {
  return async (req, res, next) => {
    try {
      const sub = await db.subscription.findUnique({
        where: { userId: req.user.id }
      });
      
      if (!sub || !['active', 'trialing'].includes(sub.status)) {
        return res.status(403).json({ error: 'Subscription required' });
      }
      
      // Check plan level
      const planHierarchy = { free: 0, starter: 1, pro: 2, enterprise: 3 };
      const userLevel = planHierarchy[sub.plan] || 0;
      const requiredLevel = planHierarchy[requiredPlan] || 0;
      
      if (userLevel < requiredLevel) {
        return res.status(403).json({ 
          error: 'Plan upgrade required',
          currentPlan: sub.plan,
          requiredPlan 
        });
      }
      
      next();
    } catch (error) {
      // Default DENY on error
      return res.status(403).json({ error: 'Access check failed' });
    }
  };
}

// Usage
app.get('/api/analytics', authenticate, requirePlan('pro'), (req, res) => {
  // Only pro+ users reach here
});
```
