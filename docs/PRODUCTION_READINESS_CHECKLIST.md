# Production Readiness Checklist

Last reviewed: `2026-09-21T21:55:00+10:00`

Current evidence: [September 14, 2026 production rerun](PRODUCTION_READINESS_EVIDENCE_2026-09-14.md). The deployed Cornerstone command passes 26 of 29 controls, and the deployed AIRE command passes 20 of 23. Both fail only the expected production Clerk, instance-bound MFA evidence, and authenticated Clerk-instance checks. The manual controls below remain no-go until their evidence is attached.

Current manual evidence record: [Payroll operator and recovery acceptance](OPERATOR_AND_RECOVERY_ACCEPTANCE.md). Use it to assign owners and retain the results of operator, identity, restore, object recovery, queue, monitoring, and real-cycle drills.

Recurring-adjustment incident update as of `2026-09-03T09:26:38+10:00`: PR [#142](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/142) merged the correction and safe pre-deploy process. Render was configured with the direct migration connection and `bundle exec rails db:safe_prepare`; the deployment completed, and a post-deploy operator session verified the affected June 4 payroll before and after recalculation. Render shows both the API web service and background worker live on PR #142 merge `e69114531fb610bc6c4a4b9036337419428b5b74`. PR [#143](https://github.com/Shimizu-Technology/cornerstone-payroll/pull/143) changed only `web/package-lock.json` to resolve the frontend dependency advisory, so Render's path filters correctly did not rebuild the backend services. Netlify published PR #143 merge `673c0c7a84066aca017cb3b1bee49218526369d4`, and follow-up main run [33687384704](https://github.com/Shimizu-Technology/cornerstone-payroll/actions/runs/33687384704) passed. The production screenshots remain in the access-controlled session. No named independent Cornerstone reviewer is recorded in source control, so Cornerstone's accounting acceptance is still a separate business signoff. Keep direct migration URLs out of long-lived container configuration and command output; never restore blanket database-session termination. See the [redacted incident and implementation record](MARK_ACCOUNTANT_FEEDBACK_AND_RECURRING_BONUS_INVESTIGATION_2026-09-02.md).

This is the release gate for payroll and compliance workloads. Passing automated tests is necessary but does not authorize production use by itself. The release owner must attach evidence for every applicable control below.

## Automated configuration and dependency gate

Run in the release environment:

```bash
cd api
RAILS_ENV=production bin/rails production:readiness
```

When any external time source is active, `TIME_TRACKING_ALLOWED_HOSTS` must list each exact public HTTPS hostname Payroll may contact. Do not use wildcard domains, IP ranges, internal hostnames, or non-standard ports.

The command validates the effective Rails configuration rather than trusting feature-toggle strings. In production it also proves:

- primary, cache, queue, and cable database connectivity and current migrations;
- agreement between complete environment and Rails credential encryption key sets, when both are present;
- decryption of every persisted employee and time-source value, every encrypted change request, and every active session token without printing plaintext;
- a cache write/read/delete round trip;
- a recent Solid Queue process heartbeat;
- an R2 upload/read/delete round trip under the isolated `production-readiness/` prefix;
- Clerk Backend API authentication;
- Resend API authentication plus verified, sending-enabled domains matching every effective application sender; and
- public DNS resolution for every active time source.

The R2 and cache probes create random, non-customer test values and remove their exact keys in an `ensure` path. The command sends no email, creates no payroll/customer row, and never prints provider responses or secret-bearing exception messages. Its final `EVIDENCE` line is safe to retain with release artifacts.

`REQUIRE_MFA=true` is an operational attestation: MFA must also be enforced and verified in the Clerk production dashboard. `CLERK_MFA_ATTESTED_INSTANCE_ID` binds that attestation to the instance returned by Clerk's authenticated API, and `CLERK_MFA_EVIDENCE_REF` records the non-secret reference for the independently reviewed provider evidence. The application still cannot inspect Clerk's provider-side MFA policy directly, so missing independent evidence is a failed control even when the runtime check passes.

## Liveness and dependency health

Render uses `GET /up` as the liveness check. That endpoint proves the Rails process booted; it intentionally does not query PostgreSQL or Solid Queue. Keep it as the platform health check so a temporary dependency problem does not create a restart loop.

Use `GET /health/dependencies` for external readiness monitoring on either web surface. It performs read-only checks for primary-database connectivity, `transaction_read_only`, `pg_is_in_recovery()`, and a Solid Queue worker heartbeat within five minutes. It returns `200 {"status":"ok"}` when all checks pass and `503 {"status":"degraded"}` otherwise. The public response does not expose exception text, database identifiers, payroll data, or individual check results.

Rack::Attack has its own bounded 16 MB MemoryStore by default. Clerk JWKS and
the tenant registry use a separate process-local cache. These caches keep
request-path safeguards available during a read-only PostgreSQL incident.

Before adding Puma workers or a split web service, set the same
`RACK_ATTACK_REDIS_URL` on every web process. It accepts Redis or Valkey via
`redis://` or `rediss://` and is scoped to rate-limit counters. Production
readiness requires a configured shared URL when `WEB_CONCURRENCY > 1` or
`APP_PROCESS_ROLE` selects a split role. If the shared store is unreachable,
requests fall back to local counters with a warning and retry Redis after five
seconds. Limits are per process during that fallback. Watch Render logs for
`Shared counters unavailable`.

## Payroll web and employee capacity

Keep `APP_PROCESS_ROLE=all` (also the default) on the current Render services. The future
`payroll_web` role mounts the admin, client, finance, integration, form 500, company,
cable-ticket, and notification-settings APIs and the `/cable` WebSocket. The
future `employee_web` role mounts employee and kiosk APIs as they become
available. Both serve `/up`, `/health/dependencies`, auth, and public tenant
branding. The Rails storage and mailbox routes remain available on `all`.

The November 23 preflight measured one Render Standard web service and one
Standard worker service in Singapore, each configured with 2 GB. The observed
process RSS was approximately 230 MB. Reserve independent database capacity
with `DB_POOL_MAX`, a positive limit **per Active Record pool and per OS process**.
When unset, Rails falls back to `RAILS_MAX_THREADS` or 5. Include all four pools
(primary, cache, queue, and cable) when budgeting web connections. Keep
`DATABASE_URL` pooled with prepared statements disabled and use the direct
`MIGRATION_DATABASE_URL` for pre-deploy migrations. Keep pool-size settings out
of the database URL query string.

The worker still has two entries. The main worker uses three threads and polls
`default`, `solid_queue_recurring`, then `employee` in that order. OCR keeps
its own single-thread worker. Solid Queue rejects a primary or queue
pool below the largest worker thread count plus two (5 with the standard
configuration). Use `SOLID_QUEUE_QUEUES` for a comma-separated main-worker queue
override. To add a separate employee process later, use a dedicated
`SOLID_QUEUE_CONFIG` with just the employee worker and remove `employee` from
the payroll worker's override. Run recurring scheduling on one supervisor and
include the extra process and pools in the memory and connection budget.
The preflight indicates room for another process, and the current release uses
the existing two.

### Employee and kiosk limits

| Traffic | Limit |
| --- | --- |
| Employee API | 120 per IP per minute |
| Employee activation and invitation POSTs | 10 per IP and 5 per token per 15 minutes |
| Employee PDF requests | 15 per IP per minute |
| Kiosk API | 60 per IP per minute |

These limits are scoped to `/api/v1/employee` and `/api/v1/kiosk`. The activation
limiter matches `activate`, `activation`, `invites`, and `invitations` below the
employee prefix. Activation POSTs must use `application/json` with a nonempty
top-level `token` in a body of at most 4 KiB. Rack::Attack rejects unsupported
media types and oversized bodies before dispatching to Rails. PDF limits
cover pay-stub and W-2 download paths. The existing API-wide limit still
counts all API traffic per IP.

### Employee web service readiness

When `APP_PROCESS_ROLE=employee_web`, `production:readiness` adds four checks: the booted process has no payroll routes or `/cable`, `DB_POOL_MAX` is 1 to 3 and equals the effective primary pool, the rate-limit counters are on the shared Redis store (not process-local memory), and `CLERK_AUTHORIZED_PARTIES` is set. Other roles skip them. Setup steps, the Neon connection budget, alerts and rollback are in the [M4 employee platform runbook](rollout/M4_EMPLOYEE_PLATFORM_RUNBOOK.md). The service definition is in `ops/render/employee-web.render.yaml`.

### Runtime telemetry

Render logs include JSON payloads with the process role. Filter by `event`.

- `http.request` records status and duration for requests that take at least
  500 ms or return a 5xx. Fast routine traffic stays out of the structured stream.
- `db.pool_checkout` records acquisition waits of at least 50 ms, including
  time spent obtaining a new connection. Check pool sizing and concurrent load
  when these events rise.
- `db.slow_query` records uncached SQL taking over one second. The payload
  contains timing only.
- `http.rate_limited.payroll` records every 429 and emits a Rails notification
  of the same name with `count: 1` and the throttle name. Sum `count` by
  throttle and process role in the logs. The payload omits paths, tokens, IP
  addresses, SQL, and bind values.

### Netlify build settings

The production site uses base `web`, command `npm run build`, and publish
directory `dist`. Netlify finds [`web/netlify.toml`](../web/netlify.toml) from
that base. Its command and publish values match the UI and take precedence.
Keep `VITE_APP_SURFACE=staff` (the default) for the current site. The
`employee` build is a separate entry that excludes staff routes and page
modules. It is built by a second Netlify site that reads the same
`web/netlify.toml` and sets `VITE_APP_SURFACE=employee`. For that surface the
`postbuild` step (`web/scripts/finalize-surface-dist.mjs`) writes `_headers`
and `_redirects` into `dist` and removes staff-only files; for Payroll it does
nothing. The employee site also skips every non-production build. [Netlify monorepo configuration](https://docs.netlify.com/build/configure-builds/monorepos/)

The preflight found Git-triggered production builds stopped. Continue the
existing manual release process. If Git builds are enabled later, the ignore
command skips production diffs limited to docs or the API. Changes to `web/`,
root lockfiles, `.gitignore`, or other watched build inputs run the build. Missing commit
history and non-production contexts also run the build. Verify the rule with
`bash web/scripts/test-netlify-ignore-build.sh` from the repository root.
[Netlify ignore commands](https://docs.netlify.com/build/configure-builds/ignore-builds/)

## Release evidence

- [ ] Production and staging use separate databases, Clerk instances/keys, R2 buckets, and email credentials.
- [ ] `AUTH_ENABLED=true`; test/bypass identities are unavailable in production.
- [ ] Clerk uses production (`pk_live_`/`sk_live_`) keys. A development instance is not accepted for a live payroll tenant.
- [ ] Clerk requires MFA for privileged firm users, and at least two administrators have tested enrollment and recovery.
- [ ] Roles are least-privilege; a client user cannot access another company by changing an ID in a URL or request.
- [ ] TLS is forced end-to-end; secure cookies and HSTS are visible from the public endpoint.
- [ ] CORS contains only approved HTTPS frontend origins.
- [ ] Active Record encryption uses one authoritative, recoverable key set. If both Rails credentials and deployment environment keys exist, they match exactly.
- [ ] R2 is private, lifecycle/versioning policy is documented, and a generated payroll document remains available after an application redeploy.
- [ ] Solid Queue, Cache, and Cable schemas are installed; a queued job survives a web-process restart.
- [ ] Production schema preparation runs only in the serialized pre-deploy phase, uses `db:safe_prepare` with every required direct `MIGRATION_*_DATABASE_URL`, and cannot run from a web/worker entrypoint or continue through a pooled migration. Kamal direct migration URLs are scoped to its one-off pre-deploy container and are absent from long-lived runtime configuration.
- [ ] Before creating any private personal finance book, confirm the API web and worker services run the owner-scoped finance-book revision from PR #275 or newer. Once a personal book exists, do not manually roll either service back to an earlier revision: older organization-scoped code lacks the owner check. Recover by rolling forward to a compatible revision. If rollback below that revision is unavoidable, first move or remove personal book data under a reviewed recovery plan; the migration itself refuses to roll back while personal books exist.
- [ ] Email delivery, bounce/error reporting, and sender-domain authentication are verified.
- [ ] Database backups are encrypted; restore to an isolated environment has been timed and verified.
- [ ] Object-storage backup/recovery has been exercised.
- [ ] Error monitoring, uptime monitoring, and alert ownership are configured without leaking SSNs, tax IDs, or payroll values.
- [ ] API throttling is enabled and its limits are load-tested against the largest expected payroll run.
- [ ] Dependency audit, Brakeman, all backend tests with zero pending examples, frontend gate, public Playwright checks, and the deterministic payroll browser lane pass at the release commit.
- [ ] The required `backend`, `frontend`, and `browser` GitHub checks were produced from the current PR head against current `main`; no stale-base result or skipped authenticated test is accepted.
- [ ] A representative payroll is calculated, reviewed, approved, committed, exported, and reconciled in staging.
- [ ] W-2GU, 1099-NEC, and Federal Form 941 outputs are compared to authoritative source instructions and a known-good fixture for the filing year.
- [ ] Filing outputs show blockers—not silent estimates—when historical taxable bases or 2026 tip/overtime occupation data are incomplete.
- [ ] Audit logs capture privileged changes and are exportable for incident review.
- [ ] Incident response, breach escalation, rollback, and payroll correction owners are named.

## Phase 0 payroll evidence

- [ ] Every active employee has a W-4 version and effective date; pre-2020 forms are blocked until explicitly supported.
- [ ] Filing status values use supported W-4 semantics; legacy `married_separate` data has been normalized.
- [ ] Each calculated payroll item stores the annual tax configuration ID, taxable wage bases, and rule snapshot used for calculation.
- [ ] Cash tips, service-charge wages, and qualified overtime are stored as separate facts.
- [ ] Tipped occupations and effective dates are complete for employees whose 2026 W-2 reporting requires them.
- [ ] 1099 thresholds are selected by filing year from versioned data.
- [ ] Recalculation and correction behavior preserves the original calculation evidence and audit trail.

## Go/no-go rule

Any failed automated check, missing required evidence, cross-tenant access defect, unexplained payroll variance, or filing blocker is a no-go. The release owner records the failure, assigns an owner, and reruns the complete gate after remediation.

Do not change Clerk keys as an isolated environment edit. A production-instance cutover requires a maintenance window, an inventory of current privileged users, production-instance invitations or migration, MFA enrollment/recovery verification for at least two administrators, frontend and backend key changes as one release, and a tested rollback path. Silent lockout is a failed release.
