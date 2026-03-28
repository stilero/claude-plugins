# ADR Template

Architecture Decision Records (ADRs) follow the format by Michael Nygard.
Each ADR documents a significant architectural decision made in the project.

## File Naming

```
.knowledge-bank/adr/ADR-<NNNN>-<slug>.md
```

Examples:
- `ADR-0001-use-postgresql-as-primary-database.md`
- `ADR-0002-adopt-event-sourcing-for-order-service.md`
- `ADR-0003-deprecate-legacy-auth-service.md`

## ADR Statuses

- **Proposed** — Under discussion, not yet accepted
- **Accepted** — The decision has been made and is in effect
- **Deprecated** — Was accepted but no longer applies
- **Superseded by ADR-NNNN** — Replaced by a newer ADR

## Template

```markdown
---
id: "0001"
adr: "ADR-0001"
title: "Use PostgreSQL as Primary Database"
date: "2026-03-28T14:30:00"
category: adr
status: Accepted
tags: [database, postgresql, architecture]
supersedes: ""
superseded_by: ""
---

# ADR-0001: Use PostgreSQL as Primary Database

**Status:** Accepted
**Date:** 2026-03-28

## Context

Describe the situation, forces, and constraints that led to this decision.
What is the problem we're solving? What options were considered?

Be specific. Mention:
- The business or technical driver
- Any constraints (team expertise, cost, existing infrastructure)
- Options that were evaluated

## Decision

State the decision clearly and directly.

"We will use PostgreSQL as the primary database for all persistent storage."

Include the key reasons this option was chosen over alternatives.

## Consequences

### Positive
- What becomes easier or possible because of this decision
- Benefits gained

### Negative
- What becomes harder or new problems this creates
- Technical debt incurred
- Risks introduced

### Neutral
- Changes in process or tooling that are neither good nor bad

## Options Considered

### Option 1: PostgreSQL ✅ (chosen)
Brief description and key tradeoffs.

### Option 2: MySQL
Brief description and why it was not chosen.

### Option 3: MongoDB
Brief description and why it was not chosen.

## Related

- ADR-0002: ...
- [External reference](https://example.com)
```

## Example — Completed ADR

```markdown
---
id: "0003"
adr: "ADR-0003"
title: "Adopt Server-Side Rendering for Dashboard"
date: "2026-02-10T09:00:00"
category: adr
status: Accepted
tags: [frontend, ssr, performance, nextjs]
supersedes: ""
superseded_by: ""
---

# ADR-0003: Adopt Server-Side Rendering for Dashboard

**Status:** Accepted
**Date:** 2026-02-10

## Context

The dashboard page has a Time-to-First-Contentful-Paint of 4.2s on mobile due to
client-side data fetching. Users on slow connections see a blank screen for several
seconds. We need to improve initial load performance without a full rewrite.

## Decision

We will adopt Next.js Server-Side Rendering (SSR) for the dashboard page. Data will
be fetched on the server at request time and delivered as pre-rendered HTML.

## Consequences

### Positive
- TTFCP drops to ~800ms on mobile
- Better SEO for any public-facing dashboard views
- Simplified client-side state (no loading spinners for initial data)

### Negative
- Server costs increase due to per-request rendering
- Cache invalidation becomes more complex
- Team needs familiarity with Next.js SSR patterns

## Options Considered

### Option 1: SSR with Next.js ✅ (chosen)
Best performance for initial load. Team already uses Next.js.

### Option 2: Static Generation (SSG)
Not viable — dashboard data changes per user and is frequently updated.

### Option 3: Client-side with optimistic UI
Already tried. 4.2s TTFCP is unacceptable for the target market.
```
