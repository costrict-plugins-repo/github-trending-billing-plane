# Next.js App Router — Stripe Billing Patterns

## File Structure
```
app/
├── api/
│   ├── stripe/
│   │   ├── checkout/route.ts      # POST: Create checkout session
│   │   ├── webhook/route.ts       # POST: Handle Stripe webhooks
│   │   ├── portal/route.ts        # POST: Create customer portal session
│   │   └── entitlements/route.ts  # GET: Check user's current plan
│   └── ...
├── (billing)/
│   ├── pricing/page.tsx           # Pricing page (server component)
│   ├── success/page.tsx           # Post-checkout landing (polls status)
│   └── cancel/page.tsx            # Checkout cancelled page
├── lib/
│   ├── stripe.ts                  # Stripe client (server-only)
│   ├── stripe-config.ts           # Price/product config from env vars
│   └── entitlements.ts            # Feature gating utilities
└── ...
```

## Critical: Webhook Route Config

Next.js App Router requires raw body for webhook signature verification:

```typescript
// app/api/stripe/webhook/route.ts
import { headers } from 'next/headers';
import { stripe } from '@/lib/stripe';
import { processWebhookEvent } from '@/lib/stripe-webhook-handler';

// CRITICAL: Disable body parsing for webhook signature verification
export const dynamic = 'force-dynamic';

export async function POST(req: Request) {
  const body = await req.text(); // raw body, not parsed JSON
  const headersList = await headers();
  const sig = headersList.get('stripe-signature');

  if (!sig) {
    return new Response('Missing stripe-signature header', { status: 400 });
  }

  let event;
  try {
    event = stripe.webhooks.constructEvent(
      body,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET!
    );
  } catch (err) {
    console.error('Webhook signature verification failed:', err);
    return new Response('Webhook signature verification failed', { status: 400 });
  }

  // Process idempotently
  await processWebhookEvent(event);
  return new Response(JSON.stringify({ received: true }), { status: 200 });
}
```

## Server-Only Stripe Client

```typescript
// lib/stripe.ts
import 'server-only'; // This import prevents client-side bundling
import Stripe from 'stripe';

export const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2024-12-18.acacia',
  typescript: true,
});
```

## Checkout Session Creation

```typescript
// app/api/stripe/checkout/route.ts
import { NextResponse } from 'next/server';
import { auth } from '@/lib/auth';
import { stripe } from '@/lib/stripe';
import { getOrCreateStripeCustomer } from '@/lib/stripe-customers';

export async function POST(req: Request) {
  const session = await auth();
  if (!session?.user) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const { priceId } = await req.json();
  
  // Validate priceId against allowed values (never trust client input)
  const allowedPrices = [
    process.env.STRIPE_PRICE_PRO_MONTHLY,
    process.env.STRIPE_PRICE_PRO_YEARLY,
  ];
  if (!allowedPrices.includes(priceId)) {
    return NextResponse.json({ error: 'Invalid price' }, { status: 400 });
  }

  const customerId = await getOrCreateStripeCustomer(session.user);

  const checkoutSession = await stripe.checkout.sessions.create({
    customer: customerId,
    mode: 'subscription',
    line_items: [{ price: priceId, quantity: 1 }],
    success_url: `${process.env.NEXT_PUBLIC_APP_URL}/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${process.env.NEXT_PUBLIC_APP_URL}/pricing`,
    metadata: {
      userId: session.user.id, // Link session to your user
    },
  });

  return NextResponse.json({ url: checkoutSession.url });
}
```

## Success Page — Polls, Never Trusts Redirect

```typescript
// app/(billing)/success/page.tsx
'use client';
import { useEffect, useState } from 'react';

export default function SuccessPage() {
  const [status, setStatus] = useState<'loading' | 'active' | 'processing'>('loading');

  useEffect(() => {
    const checkStatus = async () => {
      const res = await fetch('/api/stripe/entitlements');
      const data = await res.json();
      setStatus(data.subscriptionStatus === 'active' ? 'active' : 'processing');
    };
    
    checkStatus();
    // Poll every 2 seconds until active (webhook may not have arrived yet)
    const interval = setInterval(checkStatus, 2000);
    return () => clearInterval(interval);
  }, []);

  if (status === 'loading') return <p>Checking your subscription...</p>;
  if (status === 'processing') return <p>Processing your payment. This usually takes a few seconds...</p>;
  return <p>Welcome to Pro! Your subscription is active.</p>;
}
```

## Environment Variables Required

```env
# Server-only (NEVER prefix with NEXT_PUBLIC_)
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_PRICE_PRO_MONTHLY=price_...
STRIPE_PRICE_PRO_YEARLY=price_...

# Client-safe
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_live_...
NEXT_PUBLIC_APP_URL=https://yourdomain.com
```
