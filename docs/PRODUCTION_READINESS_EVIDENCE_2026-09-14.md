# Production readiness evidence — September 14, 2026

This record captures safe deployed checks after the final payroll implementation and MFA-evidence hardening merged. It does not authorize a production payroll or replace the named operator, identity, recovery, parallel-cycle, and signoff requirements.

## Deployed revisions

| Application | Revision | Deployment evidence | Public health |
| --- | --- | --- | --- |
| Cornerstone web | `5684338d9689c6ebe71e1f9cd8fe05b0a73575e1` | Render deploy `dep-dajoecgu01pc739a0sd0` live at `2026-09-14T05:35:06Z` | `200` with HSTS |
| Cornerstone worker | `5684338d9689c6ebe71e1f9cd8fe05b0a73575e1` | Render deploy `dep-dajoecgu01pc739a0st0` live at `2026-09-14T05:34:23Z` | Recent heartbeat passed |
| AIRE API | `32fe0791d8ede942f40fdaf8610939b74d803075` | Render deploy `dep-dajo6pgu01pc7399rpf0` live at `2026-09-14T05:18:25Z` | `200` with HSTS |

No production payroll, time approval, cutoff, finalization, payment, filing, email, user invitation, or identity-key change was performed while collecting this evidence.

## Cornerstone deployed gate

The safe `RAILS_ENV=production bin/rails production:readiness` task ran on the deployed web service at `2026-09-14T05:37:58Z`.

- **Result:** 26 of 29 controls passed.
- **Passed:** production environment, authentication enabled, TLS, R2, Solid Cache, Solid Queue, Solid Cable, trusted proxies, explicit CORS origins, production mailer URL, R2/Resend/time-source configuration, encryption presence and source agreement, 2026 payroll tax configuration, primary/queue/cable database access, current migrations, persisted-data decryption, cache round trip, recent worker heartbeat, R2 upload/read/delete cleanup, Resend sender-domain readiness, and public time-source DNS safety.
- **Failed as designed:** instance-bound MFA evidence, live Clerk keys, and Clerk Backend API authentication against the attested instance.
- **Root cause:** the coordinated production Clerk/MFA cutover has not been authorized and completed. These are release blockers, not application or infrastructure failures.

## AIRE deployed gate

The safe `RAILS_ENV=production bin/rails production:readiness` task ran on the deployed AIRE service at `2026-09-14T05:38:01Z`.

- **Result:** 20 of 23 controls passed.
- **Passed:** production environment, TLS, S3, Solid Queue and in-process worker, explicit frontend origin, S3/Resend/integration configuration, encryption, cutoff and delivery schedules, database access, current migrations, worker heartbeat, S3 upload/read/delete cleanup, Clerk JWKS reachability, Resend sender readiness, Cornerstone health reachability, and absence of overdue payroll-event delivery failures.
- **Failed as designed:** instance-bound MFA evidence, live Clerk credentials, and Clerk Backend API authentication against the attested instance.
- **Root cause:** AIRE still needs its approved hostname, production Clerk instance, MFA/recovery evidence, and coordinated key switch.

## Release disposition

The deployed code and non-identity infrastructure are healthy. Production payroll remains **no-go** until the identity cutover and every applicable manual acceptance row in [Payroll operator and recovery acceptance](OPERATOR_AND_RECOVERY_ACCEPTANCE.md) are complete. Do not set `REQUIRE_MFA=true` or either MFA evidence value before provider enforcement and independent recovery evidence exist.
