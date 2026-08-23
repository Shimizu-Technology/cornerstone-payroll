# Production readiness evidence: August 24, 2026

**Environment:** Render production

**Audited revision:** `1d19362354059ef05e9d7ccd88d230bae92c2bd6`

**Audit type:** deployed effective-configuration checks, safe live dependency probes, provider-console inspection, and release-evidence review

**Automated result:** 24 of 26 controls passed

**Overall result:** No-go until the coordinated Clerk production/MFA cutover and the remaining manual controls are evidenced

## Executive result

Gate 0's code work is merged. PR #133 added the effective production-readiness service and task; Greptile reported 5/5 on final head `2974a75`, the required GitHub checks passed, merge commit `1d19362` reached `main`, and Quality run `32640601945` passed.

The deployed command now proves the production application can reach its primary database, Solid Cache, Solid Queue, Solid Cable, R2, Resend, Clerk, and both external time-source destinations. It also proves current migrations, a recent worker heartbeat, exact time-source allowlisting, public-only destination DNS, production authentication, TLS, explicit CORS origins, effective encryption keys, and the configured sender domains.

The final one-off job, `job-da5g1ojbc2fs738uld00`, ran against deployed revision `1d19362` and passed 24 of 26 controls. The only failures were:

- the application still uses Clerk development key classes instead of `pk_live_` and `sk_live_`; and
- provider-side MFA enforcement has not been enabled and attested.

Those are real release blockers, not false negatives. The Clerk dashboard identifies Cornerstone Payroll as having **No Production Environment**. Its current development instance contains existing user records, all MFA strategies are off, and **Require multi-factor authentication** is disabled. Changing keys or enforcing MFA without a user migration, enrollment, recovery, and rollback plan could lock current Cornerstone users out.

## Remediation proved in production

| Control | Remediation and evidence | Result |
| --- | --- | --- |
| Release implementation | PR #133 merged as `1d19362`; `main` Quality run `32640601945` passed; web and worker deployed that revision. | Verified |
| Authentication toggle | The effective web value is `AUTH_ENABLED=true`; an unauthenticated admin API probe returned HTTP 401; the final readiness job passed the control. | Verified |
| Shared web/worker stores | The worker was moved to the web service's durable database target while the previous worker database was retained for rollback. The final web-side probe passed primary, queue, cache, cable, and recent worker-heartbeat checks. | Verified for connectivity and heartbeat; restart durability still requires the manual exercise below |
| Mail configuration | `MAILER_FROM_EMAIL` was made explicit on web and worker. A new dedicated full-access Resend key was created, installed on both services, exercised by the live domains endpoint, and observed as used. Superseded Cornerstone Payroll keys created during remediation were revoked. | Verified |
| Sender domain | The final probe authenticated to Resend and confirmed every effective application sender domain is verified and sending-enabled. | Verified |
| External time destinations | `TIME_TRACKING_ALLOWED_HOSTS` is exactly `aire-services.onrender.com,cornerstone-tax.onrender.com` on web and worker. The final probe resolved both names and rejected any non-public answer. | Verified |
| Render health monitoring | The web service health-check path is `/up`; the public endpoint returned HTTP 200 with HSTS after the live deploy. | Verified |
| Active Record encryption | Production now uses the same effective environment-or-credentials binding that readiness checks. The final deployed probe passed. | Verified |
| R2 basic operation | The isolated `production-readiness/` upload/read/delete round trip passed with exact cleanup. | Verified; recovery/versioning is not yet verified |

## Remediation audit trail

The readiness gate caught a configuration mistake during the mail/authentication remediation: a browser coordinate edit assigned a replacement mail key to the wrong Render variable. No key was committed to source control. The live probe failed, the values were compared by key through Render's API, the exact variables were repaired through that API, a fresh dedicated mail key was installed on both services, and every superseded Cornerstone Payroll key was revoked. The final job then passed both authentication and Resend controls.

This incident is why release evidence must come from effective configuration and provider calls after deployment. A dashboard save or a successful deploy is not proof that the intended key received the intended value.

The former worker database credential was also visible in the internal remediation transcript while the split-brain connection was being diagnosed. The worker no longer uses that database, and the database was retained only as a rollback artifact. Its credential must still be treated as exposed: rotate it immediately if the database remains in the rollback window, or retire the database and credential after an approved retention decision. No credential value is retained in this repository.

## Final automated job evidence

| Job | Deployed state tested | Outcome |
| --- | --- | --- |
| `job-da5eqobbc2fs738qmpr0` | First run of the replacement readiness task | Failed seven controls and established the remediation baseline. |
| `job-da5f5h3ncjis738nolb0` | Shared stores, allowlist, health path, and sender configuration applied | Failed only Clerk/MFA and Resend provider readiness. |
| `job-da5fjfjncjis738p123g` | First mail-key rotation before old-key revocation | Resend passed; authentication attestation and Clerk/MFA remained open. |
| `job-da5fofjtqb8s73ab2k60` | Misassigned environment value | Failed and prevented a false closure. |
| `job-da5fu63ncjis738q1cdg` | Exact Render-variable repair, before the final mail-key rotation | Authentication passed; the invalid mail key was still rejected. |
| `job-da5g1ojbc2fs738uld00` | Final key rotation and clean web/worker deploys | 24/26 passed. Only Clerk production keys and MFA failed. |

## Automated blockers requiring a coordinated cutover

### Clerk production identity

Cornerstone Payroll has no Clerk production environment. The current live application uses the development instance and has existing users. Closing this control requires one coordinated release:

1. inventory every current user and identify at least two privileged recovery administrators;
2. choose and document invitation, migration, or recreation semantics for those identities;
3. create the Clerk production instance and reproduce the approved sign-in, session, domain, and organization policy;
4. enable at least one supported MFA strategy, enroll the recovery administrators, and test recovery;
5. update frontend and backend Clerk keys together during a maintenance window;
6. test signed-out, staff, client, inactive-user, and Cable behavior in production;
7. retain the prior key set and deploy as a time-bounded rollback path; and
8. set `REQUIRE_MFA=true` only after provider enforcement is proven, then rerun the complete readiness command.

This work cannot be reduced to replacing two environment strings. Silent lockout is a failed cutover.

## Manual controls still not verified

The automated gate deliberately cannot close these controls:

| Control | What is already proved | Missing acceptance evidence | Owner |
| --- | --- | --- | --- |
| Database backup and restore | Live database queries and migrations pass. | Restore the production backup to an isolated environment, time it, reconcile expected data, and destroy or retain it under an approved policy. | Unassigned |
| Legacy worker database credential | The worker now uses the web service's durable database target; the former database is disconnected. | Rotate the exposed legacy credential if the database is retained, or retire the database and credential after an approved rollback/retention decision. | Unassigned |
| R2 recovery/versioning | Live isolated upload/read/delete passes. | Prove versioning or backup policy and recover a deleted/replaced generated payroll document. | Unassigned |
| Queue restart durability | Shared stores and a recent worker heartbeat pass after redeploy. | Enqueue an isolated probe, restart the web service, and prove the worker completes the same queued job exactly once. | Unassigned |
| Error and uptime monitoring | `/up` is configured and healthy. | Name alert recipients, test delivery, and review logs/events for SSN, tax-ID, bank, and payroll-value leakage. | Unassigned |
| API throttling | Application security tests pass. | Load-test configured limits against the largest expected payroll and document safe failure behavior. | Unassigned |
| Representative payroll | Deterministic synthetic browser and backend lanes pass. | Run, approve, commit, export, and reconcile a production-shaped staging payroll with a Cornerstone reviewer. | Unassigned |
| Filing certification | Filing regression tests pass. | Compare W-2GU, 1099-NEC, and Form 941 outputs against applicable filing-year instructions and known-good fixtures. | Cornerstone reviewer unassigned |
| Incident and correction ownership | Correction and audit mechanisms exist in code. | Name incident, rollback, breach-escalation, and payroll-correction owners and run a tabletop exercise. | Unassigned |

## Current disposition

G0-19 is code-closed and partially operationally verified. It is not operationally closed. The next release decision must first resolve the Clerk cutover and assign owners for the manual evidence above. After that evidence is attached, rerun `production:readiness` on the final deployed revision; all 26 automated checks must pass before a production go decision.

The initial failed audit remains at [Production readiness evidence: August 23, 2026](PRODUCTION_READINESS_EVIDENCE_2026-08-23.md).
