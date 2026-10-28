# saas-starter

[![CI](https://github.com/MahyarNemati/saas-starter/actions/workflows/ci.yml/badge.svg)](https://github.com/MahyarNemati/saas-starter/actions/workflows/ci.yml)

A multi-tenant SaaS foundation on Next.js 15 and Postgres where **tenant
isolation is enforced by the database, not by application code**: organizations
with roles and invitations, Stripe billing with idempotent webhooks, hashed API
keys, durable rate limiting and audit logs.

## Quickstart

```bash
cp .env.example .env.local        # set DATABASE_URL and AUTH_SECRET
npm install
npm run db:migrate
npm run dev
```

Or the whole thing with Postgres included:

```bash
docker compose up --build
```

## The one idea worth taking from this repo

Almost every multi-tenant tutorial isolates tenants like this:

```ts
db.select().from(projects).where(eq(projects.orgId, orgId)); // 🤞
```

That is one forgotten `where` clause away from a cross-tenant data leak, and
the forgotten clause is invisible — the query runs fine and returns _more_ than
it should. No test you did not think to write will catch it.

Here, isolation is a property of the **connection**, not the query:

```ts
await withTenant(db, { orgId, userId }, async (tx) => {
  // Inside this transaction, Postgres itself filters every read and rejects
  // every write that targets another org — whatever the query says.
  return tx.select().from(projects);
});
```

`withTenant` ([`src/db/tenant.ts`](src/db/tenant.ts)) opens a transaction and:

1. sets `app.current_org` and `app.current_user` with
   `set_config(..., true)` — the `true` makes them **transaction-local**, so
   they cannot leak to the next borrower of a pooled connection;
2. issues `SET LOCAL ROLE app_tenant`, dropping from the schema owner to an
   unprivileged role that row-level security actually applies to.

That second step is the part people miss. RLS policies are **bypassed by the
table owner**, so an application connecting as the owner gets policies that
silently do nothing. Writing the policies is not enough; you have to stop being
the owner for the duration of the query.

The policies read `app_current_org()`, so a query for another org returns zero
rows and a write to another org is rejected by the database. Forgetting a
`where` clause becomes a non-event.

### Why `tests/rls.test.ts` is the most important file here

A claim like "cross-tenant access is impossible" is worth exactly as much as the
test that proves it. That suite creates two organizations and asserts that
tenant A cannot read, update, insert into or delete tenant B's rows — by trying.

It runs in CI against a real Postgres, and CI additionally **asserts the suite
was not skipped**, because a skipped suite and a passing suite look identical in
a green tick:

```yaml
- name: Assert the RLS suite really ran
  # fails if 0 RLS assertions passed, or any were pending
```

That guard exists because the suites skip without `TEST_DATABASE_URL`, and a
silently-skipping security test is worse than no test — it produces false
confidence.

## What else is in here

| Area              | Notes                                                                     |
| ----------------- | ------------------------------------------------------------------------- |
| **Organizations** | create, membership, seat limits tied to the plan                          |
| **Roles**         | `owner` / `admin` / `member` with a central `rbac.ts` check               |
| **Invitations**   | tokenised invites, acceptance, revocation                                 |
| **Billing**       | Stripe checkout + customer portal, plan entitlements, idempotent webhooks |
| **API keys**      | per-org, **hashed at rest**, prefix-identifiable, revocable               |
| **Rate limiting** | token bucket; Postgres-backed (shared) or in-memory (per-process)         |
| **Audit log**     | append-only record of who did what in which org                           |
| **Email**         | Resend, or a local JSON outbox in development                             |

### Idempotent Stripe webhooks

Stripe retries. Without idempotency, a retried `checkout.session.completed`
provisions twice or double-counts a subscription change. Events are recorded
and re-delivery is a no-op, so the retry Stripe is contractually going to send
you is harmless.

The billing layer is also behind a `provider` interface
([`src/server/billing/provider.ts`](src/server/billing/provider.ts)) with a fake
used in tests — so webhook handling and entitlement logic are tested without
touching the network or a Stripe test account.

### API keys are hashed

Keys are stored as hashes, never plaintext, with a readable prefix so a user can
tell which key is which. A leaked database dump does not hand over working
credentials. This is the same reasoning as password hashing, and it is
surprising how many starters store API keys in a plain column.

### Rate limiting with a choice of backend

`RATE_LIMIT_BACKEND=postgres` shares one budget across every instance;
`memory` is per-process and only correct for a single instance. Both implement
one interface and are covered by the same tests. The default is `postgres`,
because a limiter that silently enforces N× your limit once you scale out is a
trap.

## Project layout

```
src/
  db/
    schema.ts        Drizzle schema
    client.ts        pooled connection
    tenant.ts        withTenant / enterTenant — the isolation boundary
    migrate.ts       migration runner
  env.ts             Zod-validated environment; fails fast at boot
  lib/               crypto, errors, logger
  server/
    orgs.ts  members.ts  invitations.ts  projects.ts
    rbac.ts          role checks
    api-keys.ts      hashed key issue/verify
    audit.ts         audit log writer
    rate-limit/      memory + postgres token buckets
    billing/         plans, seats, provider, stripe-provider, webhooks
drizzle/
  0000_init.sql      tables
  0001_rls.sql       the app_tenant role, helper functions and RLS policies
tests/               database-backed suites (RLS, webhooks, API keys, members)
```

## Configuration

See [`.env.example`](.env.example). Environment is validated with Zod at
startup ([`src/env.ts`](src/env.ts)), so a missing or malformed variable is a
boot-time error with a useful message rather than `undefined` surfacing three
layers deep.

Required: `DATABASE_URL`, `AUTH_SECRET` (≥32 chars).

The schema enforces things that are easy to get wrong:

- `AUTH_GITHUB_ID` and `AUTH_GITHUB_SECRET` must be set **together**.
- `STRIPE_WEBHOOK_SECRET` is required whenever `STRIPE_SECRET_KEY` is set —
  a Stripe integration with unverified webhooks is an open endpoint that
  mutates billing state.
- In production, at least one sign-in provider must be configured.

## Scripts

```bash
npm run dev            # next dev
npm run build          # next build (standalone output)
npm run lint           # eslint, zero warnings tolerated
npm run format:check   # prettier
npm run typecheck      # tsc --noEmit
npm test               # vitest
npm run db:generate    # generate a migration from schema changes
npm run db:migrate     # apply migrations
npm run db:studio      # drizzle studio
```

### Running the database suites locally

They skip unless `TEST_DATABASE_URL` points at a reachable Postgres. The global
setup creates a throwaway database per run and drops it afterwards, so it will
not touch your development data:

```bash
docker compose up -d postgres
TEST_DATABASE_URL="postgres://saas:saas@localhost:5432/postgres" npm test
```

Without it you get the 27 pure-logic tests; with it, all 66.

## CI

| Job                      | Checks                                                                                                           |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| lint, format and types   | eslint (`--max-warnings=0`), prettier, `tsc --noEmit`                                                            |
| tests against postgres   | full suite on a real Postgres, **plus a guard that the RLS suite ran**                                           |
| migrations apply cleanly | migrations run, and `db:generate` produces no diff — a schema edit without a committed migration fails the build |
| production build         | `next build`                                                                                                     |
| image builds             | Docker build                                                                                                     |

## Limitations

- **Authentication is wired but minimal.** Provider configuration exists; the
  sign-in UI is deliberately thin so you can swap in your own.
- **The UI is a starting point.** This repo is a _backend_ foundation; the
  pages are not a finished product.
- **No per-tenant schemas or databases.** Shared tables with RLS is the right
  default for most SaaS, but very large or regulated tenants sometimes need
  physical separation.
- **E2E tests are scaffolded, not written.** Playwright is configured
  (`npm run test:e2e`) but there is no meaningful suite yet.

## License

MIT.
