# Production Readiness Checklist

Last reviewed: August 23, 2026

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
- a cache write/read/delete round trip;
- a recent Solid Queue process heartbeat;
- an R2 upload/read/delete round trip under the isolated `production-readiness/` prefix;
- Clerk Backend API authentication;
- Resend API authentication plus verified, sending-enabled domains matching every effective application sender; and
- public DNS resolution for every active time source.

The R2 and cache probes create random, non-customer test values and remove their exact keys in an `ensure` path. The command sends no email, creates no payroll/customer row, and never prints provider responses or secret-bearing exception messages. Its final `EVIDENCE` line is safe to retain with release artifacts.

`REQUIRE_MFA=true` is an operational attestation: MFA must also be enforced and verified in the Clerk production dashboard. The application cannot prove a provider-side policy merely from an environment variable.

## Release evidence

- [ ] Production and staging use separate databases, Clerk instances/keys, R2 buckets, and email credentials.
- [ ] `AUTH_ENABLED=true`; test/bypass identities are unavailable in production.
- [ ] Clerk uses production (`pk_live_`/`sk_live_`) keys. A development instance is not accepted for a live payroll tenant.
- [ ] Clerk requires MFA for privileged firm users, and at least two administrators have tested enrollment and recovery.
- [ ] Roles are least-privilege; a client user cannot access another company by changing an ID in a URL or request.
- [ ] TLS is forced end-to-end; secure cookies and HSTS are visible from the public endpoint.
- [ ] CORS contains only approved HTTPS frontend origins.
- [ ] Active Record encryption keys are stored in the deployment secret manager and covered by a documented recovery process.
- [ ] R2 is private, lifecycle/versioning policy is documented, and a generated payroll document remains available after an application redeploy.
- [ ] Solid Queue, Cache, and Cable schemas are installed; a queued job survives a web-process restart.
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
