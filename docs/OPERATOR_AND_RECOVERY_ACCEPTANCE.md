# Payroll operator and recovery acceptance

This is the final evidence checklist before MoSa leaves QuickBooks Payroll or AIRE payroll is operated from Cornerstone without routine use of the AIRE application. It does not authorize a production payroll.

Software tests prove the application contract. Operator and recovery acceptance prove that named people can run and recover the deployed service. Both are required.

## Current software evidence

- [Local Cornerstone–AIRE payroll certification](LOCAL_AIRE_PAYROLL_CERTIFICATION.md) exercises the two real Rails applications over local HTTP with disposable databases and no production data.
- [Local recovery certification](LOCAL_RECOVERY_CERTIFICATION.md) provides repeatable synthetic database-restore and durable-queue restart/replay drills. It is software evidence, not a substitute for provider and named-reviewer acceptance.
- [MoSa cycle runbook](rollout/02-MOSA-CYCLE-RUNBOOK.md) is the current interface-based workflow.
- [Production readiness checklist](PRODUCTION_READINESS_CHECKLIST.md) remains the release gate for infrastructure, identity, monitoring, filing, and recovery controls.
- [Cutover gate criteria](rollout/03-CUTOVER-GATE-CRITERIA.md) requires two signed MoSa parallel cycles and explicit technical and operational approval.

## Chels's AIRE operator acceptance

Complete the local drill first. Use synthetic data only.

1. Start the local certification with `KEEP_RUNNING=true` as documented in [the local certification guide](LOCAL_AIRE_PAYROLL_CERTIFICATION.md).
2. Sign in to the local Cornerstone interface and open the printed synthetic pay-period ID.
3. Without opening AIRE, identify:
   - the regular/kiosk entry that is eligible automatically;
   - the manual entry and daily overtime that require approval;
   - the cutoff time in ChST;
   - the immutable finalized batch and processing history;
   - the hours included in the committed synthetic payroll; and
   - the four held hours scheduled for the next regular payroll and still marked unpaid.
4. Confirm that a prepared/printed check is not shown as paid, delivery is shown as issued, and no clearing state appears without reconciliation evidence.
5. Confirm that the workflow, labels, and exception explanations are understandable without developer help.
6. Stop the drill and confirm its processes, databases, files, secrets, and token are removed.

Record the result:

| Field | Evidence |
| --- | --- |
| Operator | |
| Date/time in ChST | |
| Cornerstone revision | |
| AIRE revision | |
| Completed without opening AIRE | Yes / No |
| Held/unpaid time explained correctly | Yes / No |
| Payment states explained correctly | Yes / No |
| Questions or usability blockers | |
| Operator signature | |
| Reviewer signature | |

A production shadow cycle and supervised first live cycle remain separate required evidence. Shimizu Technology must not perform or simulate those cycles against production on the operator's behalf.

## Identity and access acceptance

Do not replace Clerk keys as an isolated dashboard edit.

Use [the Cornerstone and AIRE production identity cutover runbook](PRODUCTION_IDENTITY_CUTOVER_RUNBOOK.md) for the current verified provider state, required decisions, no-lockout preconditions, coordinated key change, verification matrix, and rollback procedure.

- [ ] Revoke and reauthenticate the historical `gog` Gmail OAuth credential, then replace its local keyring password. The embedded password was removed from the current tree but remains exposed in Git history until a separately approved history rewrite is completed.
- [ ] Inventory every current Cornerstone and AIRE user.
- [ ] Name at least two privileged recovery administrators for each production identity environment.
- [ ] Create and configure production Clerk instances.
- [ ] Reproduce the approved sign-in, organization, domain, session, and invitation policies.
- [ ] Enable an approved MFA strategy and test enrollment and recovery for both recovery administrators.
- [ ] Prepare the coordinated frontend/backend key change and time-bounded rollback values.
- [ ] Test signed-out, staff, client, inactive-user, cross-company, and live-session behavior.
- [ ] Set `REQUIRE_MFA=true` only after provider enforcement is confirmed.
- [ ] Rerun the complete readiness gate on the deployed revision.

Record the maintenance window, operator, reviewer, rollback deadline, and evidence location. Never paste secret values into this file, a ticket, chat, screenshot, or command output.

## Recovery acceptance

Use isolated, access-controlled provider resources. Do not copy production payroll data to a developer laptop.

### Database restore

- [ ] Identify the encrypted production backup and its retention policy.
- [ ] Restore it to a new isolated database with restricted credentials.
- [ ] Record the start and completion time.
- [ ] Confirm migrations are current.
- [ ] Reconcile company, employee, committed-pay-period, payroll-item, final-record, audit-event, and filing-record counts against the source at the backup point.
- [ ] Have a second reviewer inspect one retained final payroll record without exporting PII.
- [ ] Destroy the isolated restore or document its owner, retention deadline, and access list.

### Payroll document recovery

- [ ] Confirm the private object store's versioning or backup policy.
- [ ] Select a non-production or specifically approved generated test document.
- [ ] Record its key, byte size, and SHA-256 digest without recording its contents.
- [ ] Replace or delete the test object under the approved drill procedure.
- [ ] Recover the prior version and confirm the exact size and digest.
- [ ] Remove drill artifacts and retain only non-secret evidence.

### Queue restart and duplicate prevention

- [ ] Enqueue a synthetic, non-payroll probe in staging.
- [ ] Record its stable idempotency identifier.
- [ ] Restart the web process while leaving the worker and durable queue available.
- [ ] Confirm the original queued probe completes exactly once after restart.
- [ ] Replay the same identifier and confirm no second effect is created.
- [ ] Confirm alerts and logs identify the retry without exposing payload or secret data.

### Monitoring and incident response

- [ ] Name primary and backup recipients for API health, worker heartbeat, AIRE cutoff/finalization, import, acknowledgement, payment, storage, and filing failures.
- [ ] Trigger each safe synthetic alert and record receipt time.
- [ ] Review application, provider, and analytics logs for SSNs, tax IDs, bank information, raw source documents, payroll amounts, session tokens, and integration secrets.
- [ ] Name the incident lead, payroll-correction owner, client-communications owner, breach-escalation owner, and rollback authority.
- [ ] Run a tabletop scenario covering an unavailable system at cutoff, a duplicate callback, an incorrect issued check, and recovery from backup.

## Acceptance record

| Control | Owner | Reviewer | Date | Evidence location | Result |
| --- | --- | --- | --- | --- | --- |
| Chels local AIRE workflow | | | | | Pending |
| Clerk production identity and MFA | | | | | Pending |
| Database restore | | | | `LOCAL_RECOVERY_CERTIFICATION.md` | Local procedure passed; isolated provider restore pending |
| Payroll document recovery | | | | | Pending |
| Queue restart and idempotency | | | | `LOCAL_RECOVERY_CERTIFICATION.md` | Local procedure passed; staging operator drill pending |
| Monitoring and incident tabletop | | | | | Pending |
| MoSa parallel cycle 1 | | | | | Pending |
| MoSa parallel cycle 2 | | | | | Pending |
| AIRE shadow cycle | | | | | Pending |
| AIRE supervised live cycle | | | | | Pending |

Any missing owner, failed drill, unexplained reconciliation difference, missing MFA recovery path, or incomplete signed payroll cycle is a no-go. Fix the cause and repeat the complete affected drill; do not waive evidence because automated tests are green.
