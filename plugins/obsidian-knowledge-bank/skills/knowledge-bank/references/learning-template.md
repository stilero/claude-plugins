# Learning / Decision / Context Template

Templates for the three general-purpose knowledge entry types.

---

## Learning Template

Use for: lessons learned, gotchas, discoveries, "I wish I'd known this" moments.

**File path:** `.knowledge-bank/learnings/YYYY-MM/YYYY-MM-DD-<slug>.md`

```markdown
---
id: "0042"
title: "JWT Tokens Silently Expire During Long Operations"
date: "2026-03-28T14:30:00"
category: learnings
tags: [auth, jwt, async, gotcha]
---

## Summary

JWT tokens can expire mid-operation when long-running async tasks are queued before
authentication checks, causing silent 401 failures that are hard to trace.

## What Happened

During a bulk import job (avg 45 min), the user's JWT expired after 30 minutes.
The job continued running server-side but all subsequent API calls silently failed
with 401 errors that were swallowed by the retry logic.

## Root Cause

Token validation happens at the job start, not per-API-call within the job.
The 30-minute token TTL was shorter than the average job duration.

## Fix / Workaround

- Use service-account tokens for long-running background jobs, not user JWTs
- Add token expiry checks at the start of each batch within a job
- Increase background-job token TTL to 2h with a scoped permission set

## Applies To

- Any background job > 15 minutes
- Any operation that queues work after an auth check

## Related

- `decisions/2026-03/2026-03-28-service-account-for-bulk-ops.md`
```

---

## Decision Template

Use for: technical choices that don't rise to the level of a formal ADR.
Lighter-weight, no options-considered section required.

**File path:** `.knowledge-bank/decisions/YYYY-MM/YYYY-MM-DD-<slug>.md`

```markdown
---
id: "0043"
title: "Use Zod for API Request Validation"
date: "2026-03-28T15:00:00"
category: decisions
tags: [validation, typescript, zod, api]
---

## Decision

Use Zod for all API request body validation going forward.

## Rationale

- Already used in 6 of 12 endpoints — standardising removes duplication
- TypeScript inference from Zod schemas eliminates separate type definitions
- Better error messages than manual validation
- Yup (the alternative) has heavier bundle size and less active maintenance

## Scope

All new API routes. Existing routes migrate opportunistically during refactors.

## Trade-offs

- Adds ~12 KB to bundle (acceptable)
- Team needs to learn Zod's refinement API for complex validations

## Related

- `context/2026-02/2026-02-15-api-validation-patterns.md`
```

---

## Context Template

Use for: background knowledge, domain explanations, system overviews, "how this works" docs.
Long-lived reference material that rarely changes.

**File path:** `.knowledge-bank/context/YYYY-MM/YYYY-MM-DD-<slug>.md`

```markdown
---
id: "0044"
title: "How the Payment Processing Pipeline Works"
date: "2026-03-28T16:00:00"
category: context
tags: [payments, stripe, pipeline, architecture]
---

## Overview

The payment pipeline consists of four stages: intent creation, confirmation, webhook
processing, and ledger update. Each stage is idempotent and can be retried safely.

## Stage 1: Intent Creation

When a user clicks "Pay", the frontend calls `POST /api/payments/intent`.
This creates a Stripe PaymentIntent and returns a `client_secret`. The intent
is stored in our DB as `status=pending`.

## Stage 2: Confirmation

Stripe's hosted payment form confirms the intent client-side. On success, Stripe
fires a `payment_intent.succeeded` webhook (see Stage 3).

## Stage 3: Webhook Processing

`/api/webhooks/stripe` receives the event. We verify the signature with
`STRIPE_WEBHOOK_SECRET`. The handler calls `PaymentService.confirm(intentId)`.

**Important:** Stripe can deliver webhooks multiple times. The handler is idempotent —
it checks `status != completed` before updating.

## Stage 4: Ledger Update

On confirm, `LedgerService.credit(userId, amount)` creates a ledger entry and
updates `payments.status = 'completed'`. This is wrapped in a DB transaction.

## Failure Modes

- Webhook delivery failure: Stripe retries for 3 days. Our handler is idempotent.
- DB transaction failure: Stripe intent remains succeeded but our DB shows pending.
  A nightly reconciliation job catches and replays these.

## Key Config

- `STRIPE_WEBHOOK_SECRET` — verify webhook signatures
- `PAYMENT_RETRY_LIMIT` — max webhook retry attempts before alerting (default: 5)

## Related

- `adr/ADR-0004-use-stripe-for-payments.md`
- `decisions/2026-01/2026-01-10-idempotent-webhook-handlers.md`
```

---

## Session Template

Use for: end-of-session summaries capturing the key work done.

**File path:** `.knowledge-bank/sessions/YYYY-MM/YYYY-MM-DD-<slug>.md`

```markdown
---
id: "0045"
title: "Session 2026-03-28: Refactor Auth Middleware"
date: "2026-03-28T18:00:00"
category: sessions
tags: [auth, middleware, refactor, jwt]
---

## Session Summary

Refactored the authentication middleware to use service-account tokens for
background jobs after discovering silent JWT expiry failures in bulk imports.

## Key Learnings

1. JWT tokens expire during long-running jobs — see `learnings/.../jwt-token-expiry.md`
2. The `withAuth()` HOC does NOT refresh tokens on retry — this is a known gap
3. Zod validation error messages need custom formatting for the mobile client

## Decisions Made

- Service accounts for all background jobs > 5 minutes
- Zod for API validation going forward (see `decisions/.../use-zod-for-api-validation.md`)

## Code Changed

- `src/middleware/auth.ts` — added token TTL check per batch in bulk jobs
- `src/services/payment.ts` — switched to service-account token
- `src/api/routes/*.ts` — migrated 4 routes to Zod validation

## Open Questions / Next Steps

- [ ] Investigate token refresh strategy for the mobile client
- [ ] ADR needed for service-account token management pattern
- [ ] Reconciliation job coverage needs expanding to cover failed webhook retries

## Notes

The `withRetry()` utility swallows 401 errors — this was the root cause of the
silent failures. Consider adding an error classifier to `withRetry()` that does
NOT retry auth errors.
```
