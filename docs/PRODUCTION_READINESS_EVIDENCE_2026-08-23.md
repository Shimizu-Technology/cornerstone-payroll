# Production readiness evidence: August 23, 2026

**Environment:** Render production

**Audited revision:** `0d42371`

**Audit type:** read-only configuration and dependency inspection plus isolated one-off Rails jobs

**Result:** No-go

> This is the initial failed audit. The remediation rerun and current disposition are recorded in [Production readiness evidence: August 24, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-24.md). The original evidence remains unchanged below so the failure and recovery trail are not erased.

## What this evidence establishes

The production web service was running the audited `main` revision. Safe probes established that Rails was in production, authentication was enabled, TLS was configured, R2 was selected for Active Storage, Solid Cache/Queue/Cable adapters were selected, explicit frontend origins and URL were present, R2 configuration existed, and effective Active Record encryption keys were bound.

No customer, employee, pay-period, check, filing, document, or email record was created or changed during this audit. The one-off jobs performed reads only. Provider responses and deployment secrets were not retained in the repository.

## Verified release blockers

| Control | Evidence | Result | Required remediation |
| --- | --- | --- | --- |
| Clerk production identity | The live web service used `pk_test_` and `sk_test_` key classes. The configured key authenticated to Clerk, but it identified a development instance. | Failed | Plan a production-instance cutover with current-user inventory, invitations or migration, two-admin MFA enrollment/recovery proof, coordinated frontend/backend key changes, and rollback. Do not rotate this as an isolated environment edit. |
| MFA | `REQUIRE_MFA` was unset and provider-side enforcement was not evidenced. | Failed | Enforce MFA in the Clerk production instance, prove enrollment and recovery for at least two administrators, then set the release attestation. |
| Background job durability | The web service had no recent Solid Queue worker heartbeat. A direct comparison proved the web and worker services were connected to different database targets; the worker was healthy only in its separate database. | Failed | Point the worker's primary/queue/cache/cable connections at the same durable stores used by the web service, redeploy it, and prove a recent worker heartbeat from the web service plus a queued job surviving a web restart. Preserve the old database until rollback risk expires. |
| Resend authentication | The configured production Resend key received HTTP 401 from the official domains endpoint. | Failed | Rotate to a valid production key on web and worker; verify that the exact configured sender domain is verified and sending-enabled. |
| External time destinations | Active sources were `aire-services.onrender.com` and `cornerstone-tax.onrender.com`, but no exact production allowlist was configured. | Failed | Set `TIME_TRACKING_ALLOWED_HOSTS` to those two exact hosts on every process that can evaluate the integration, then rerun DNS/public-address probes. |
| Render health monitoring | The web service health-check path was blank. | Failed | Set the Render health-check path to `/up` and retain an observed healthy deploy result. |
| Backups and recovery | No authenticated Neon restore or R2 recovery exercise was available during the audit. | Not verified | Restore production data to an isolated environment without exposing customer data locally; time and document the restore. Exercise R2 recovery/versioning separately. |
| Monitoring and response | Uptime/error alert destinations, PII-safe logging review, incident owner, and correction owner were not evidenced. | Not verified | Name owners, configure alert delivery, test an alert, and record rollback/correction procedures. |
| Representative payroll and filing review | No staging lifecycle reconciliation or official filing-output certification artifact was attached. | Not verified | Run a representative calculate-to-commit payroll in staging and certify filing outputs against the applicable official instructions and known-good fixtures. |

## Job evidence

The Render one-off jobs below are the provider-side audit trail. They contain no stored deployment secrets in this document.

| Job | Purpose | Outcome |
| --- | --- | --- |
| `job-da5e3oqjobas73ee4im0` | Existing production-readiness task | Failed and demonstrated that the legacy check was incomplete. |
| `job-da5e49bncjis738kt8jg` | Active time-source inventory | Identified the two production source hosts. |
| `job-da5e9nrncjis738la530` | Effective web identity/database metadata | Confirmed development Clerk key classes and recorded a non-secret database-target fingerprint. |
| `job-da5ea5ou01pc73euthl0` | Worker database and queue heartbeat | Worker healthy in a database different from the web database. |
| `job-da5ea9gjo6nc73cae9l0` | Web database and queue heartbeat | No recent worker heartbeat in the web database. |
| `job-da5eap3bc2fs738p34p0` | Resend API authentication | HTTP 401. |

## Closure requirements

The replacement `production:readiness` command must be deployed before this audit is repeated. Its retained `EVIDENCE` line must identify the deployed revision and show every automated configuration/dependency check passing. That still does not close the manual controls above.

G0-19 becomes operationally closed only when this file or a later dated evidence record links:

- a passing production command on the final merged revision;
- shared web/worker durable-store and restart proof;
- production Clerk and MFA proof without user lockout;
- valid sender-domain and time-source evidence;
- isolated database and object-storage recovery exercises;
- PII-safe monitoring and named incident/correction owners; and
- representative staging payroll and filing certification artifacts.
