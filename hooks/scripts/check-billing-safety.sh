#!/bin/bash
# BillingPlane Pre-Write Safety Check
# Runs before Claude writes/edits files to catch billing violations in real-time
# Advisory only — warns but does not block writes

FILE_CONTENT="$1"
VIOLATIONS=0

# Rule 2: Hardcoded Stripe secret keys
if echo "$FILE_CONTENT" | grep -qE 'sk_(live|test)_[a-zA-Z0-9]{10,}'; then
  echo "⚠️  BillingPlane: Hardcoded Stripe secret key detected (Rule 2)"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 1: Hardcoded price amounts in Stripe API calls
if echo "$FILE_CONTENT" | grep -qE '(unit_amount|amount)\s*[:=]\s*[0-9]{3,}'; then
  echo "⚠️  BillingPlane: Hardcoded price amount detected (Rule 1). Use env var or config map."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 1: Hardcoded Stripe Price IDs
if echo "$FILE_CONTENT" | grep -qE "price_[a-zA-Z0-9]{10,}" | grep -vq "process\.env\|STRIPE_PRICE"; then
  echo "⚠️  BillingPlane: Hardcoded Stripe Price ID detected (Rule 1). Use env var."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 7: Webhook handler without signature verification
if echo "$FILE_CONTENT" | grep -qE 'webhook|stripe.*event' && ! echo "$FILE_CONTENT" | grep -qE 'constructEvent|constructEventAsync'; then
  echo "⚠️  BillingPlane: Webhook handler without constructEvent (Rule 7)"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 5: Billing state changes in success URL handler
if echo "$FILE_CONTENT" | grep -qE 'success.*url|checkout.*success|payment.*success' && echo "$FILE_CONTENT" | grep -qE 'update.*status|set.*plan|grant.*access|activate.*subscription'; then
  echo "⚠️  BillingPlane: Success handler modifying billing state (Rule 5). State changes must come from webhooks."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 9: subscription.updated without previous_attributes
if echo "$FILE_CONTENT" | grep -qE 'subscription\.updated|subscription_updated' && ! echo "$FILE_CONTENT" | grep -qE 'previous_attributes|previousAttributes'; then
  echo "⚠️  BillingPlane: subscription.updated handler without previous_attributes check (Rule 9)"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 13: Webhook returning non-200 on errors
if echo "$FILE_CONTENT" | grep -qE 'webhook|stripe.*event' && echo "$FILE_CONTENT" | grep -qE 'res\.(status|sendStatus)\(5[0-9][0-9]\)|return.*500|statusCode.*=.*500'; then
  echo "⚠️  BillingPlane: Webhook handler returning 500 (Rule 13). Always return 200, log errors."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 6: Client-side plan checks
if echo "$FILE_CONTENT" | grep -qE "localStorage\.getItem\('plan|sessionStorage.*plan|user\.plan\s*==="; then
  echo "⚠️  BillingPlane: Client-side plan check detected (Rule 6). Use server-side entitlement check."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 15: Non-atomic balance deduction
if echo "$FILE_CONTENT" | grep -qE 'balance\s*-=|balance\s*=\s*balance\s*-' && ! echo "$FILE_CONTENT" | grep -qE 'transaction|FOR UPDATE|atomic|lua'; then
  echo "⚠️  BillingPlane: Non-atomic balance deduction detected (Rule 15). Use transaction or Redis Lua."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# Rule 11: Client-side money computation
if echo "$FILE_CONTENT" | grep -qE '(price|amount|cost|total)\s*\*\s*[0-9]|toFixed\(2\).*price'; then
  echo "⚠️  BillingPlane: Client-side money computation detected (Rule 11). Let Stripe handle math."
  VIOLATIONS=$((VIOLATIONS + 1))
fi

if [ $VIOLATIONS -gt 0 ]; then
  echo "---"
  echo "BillingPlane found $VIOLATIONS potential violation(s). Review before proceeding."
fi

exit 0  # Advisory only, never block
