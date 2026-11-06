# AIRE + Cornerstone staging v2

This stack runs individually successful `staging-v2` commits only after their exact revision pair passes connected-payroll certification. It is independent from the existing staging environment:

- Colima profile: `aire-payroll-staging-v2`
- Compose project: `aire-payroll-staging-v2`
- local ports: AIRE `8889`, payroll `8890`
- separate PostgreSQL and upload volumes
- separate service checkout, deployment state, backups, logs, and LaunchAgent

The applications communicate only over the private Compose integration network. Browser traffic reaches the Caddy frontends, which proxy same-origin API, Action Cable, and Active Storage requests. The databases and Rails containers publish no host ports.

Cornerstone stores staging-only generated artifacts in its persistent `payroll_storage` volume. Local storage is accepted only when all explicit staging guards are present; production still requires R2.

The seed fixture follows the current target-run cutoff contract: the upcoming run locks seven calendar days after the previous adjacent regular payday. It creates a finalized period for reconciliation and an upcoming period for the connected payroll workflow. All fixture people and identifiers are synthetic.

The LaunchAgent checks every three minutes for successful `staging-v2` image workflows and the exact-pair certificate described below. A temporary GitHub lookup failure leaves the current containers running. A commit pair that fails its deployment health check is held until either commit changes; an operator can rerun `deploy.sh` directly with a verified certificate after correcting an external problem. Backups run before deployment and at least daily, retain 14 days, and include both PostgreSQL databases and both upload volumes.

## Certify a revision pair before deployment

Once the two candidate commits have passed their normal quality and image publication workflows, an authorized operator dispatches the already registered `quality.yml` workflow in the payroll repository with the two optional pair inputs. Quality keeps its normal backend, frontend, browser, and staging-configuration gates and then invokes `connected-payroll.yml` as a reusable workflow. Use full 40-character SHAs, never branch names or image tags as inputs:

```bash
gh workflow run quality.yml \
  --repo Shimizu-Technology/cornerstone-payroll --ref staging-v2 \
  -f payroll_sha=FULL_PAYROLL_COMMIT_SHA \
  -f aire_sha=FULL_AIRE_COMMIT_SHA
```

Quality already exists on the default branch. Its updated task-branch revision can be dispatched before merge to test the lane; no application code needs promotion to `main` to register a second workflow. A task-branch run is test evidence only: the deployment verifier requires a successful `staging-v2` dispatch. Do not deploy a new pair while certification is pending. A dispatch without pair inputs retains the normal Quality behavior.

Before publishing the first release with this gate, an authorized operator must pause only the v2 deployment trigger and install the hardened poller/verifier in its service checkout. The previously deployed poller cannot enforce a check it does not yet contain. Certify the bootstrap pair, verify direct deployment with its run ID, and then resume the v2 trigger. Keep the original staging environment and shared host services running.

After checking the v2 service checkout is clean and recording its current commit, the authorized bootstrap sequence is:

```bash
launchctl bootout "gui/$(id -u)/com.shimizutechnology.aire-payroll-staging-v2"
git -C /Users/leonshimizu/services/aire-payroll-staging-v2 fetch origin REVIEWED_GATE_BRANCH
git -C /Users/leonshimizu/services/aire-payroll-staging-v2 checkout --detach REVIEWED_GATE_COMMIT_SHA
```

Use the reviewed gate commit that contains the schema-2 verifier, `pair_evidence.py`, public metadata reader and compatible certificate writer; record that gate revision separately from the deployed application pair. A clean checkout at an older gate revision must be bootstrapped before it can consume the new certificate. Updating these gate files does not certify the existing deployed pair or change its recorded state. Confirm their hashes match the reviewed files before merging or publishing either application. Keep all existing containers running during this file bootstrap. Then merge the reviewed application branches, wait for their exact image publications, dispatch Quality with that pair on `staging-v2`, and verify its retained certificate. Only after that succeeds:

```bash
/Users/leonshimizu/services/aire-payroll-staging-v2/ops/staging-v2/deploy.sh \
  FULL_PAYROLL_COMMIT_SHA FULL_AIRE_COMMIT_SHA CERTIFICATE_RUN_ID
launchctl bootstrap "gui/$(id -u)" \
  /Users/leonshimizu/Library/LaunchAgents/com.shimizutechnology.aire-payroll-staging-v2.plist
```

Do not resume a trigger from an older checkout. The checked-out gate commit and the application images are distinct during bootstrap; deployment records the successfully installed image pair and certificate only after its health check passes. If either certificate or deployment fails, preserve the held state and recover through the reviewed procedure before resuming the trigger.

CI checks out both immutable revisions, uses each application's pinned Ruby, and runs `scripts/certify_aire_payroll_integration.sh` against two new, empty synthetic test databases. The drill exercises the actual HTTP boundary, calendar publication, approvals, cutoff finalization, batch import, payroll commitment, and exact payment acknowledgements. It cleans its own databases, servers, token, and temporary files. The accelerated synthetic cutoff tests state transitions; literal 17:00 Guam and scheduled-payday policy still requires the calendar tests and operator evidence.

The release uploads two non-secret evidence artifacts: `connected-payroll-pair-RUN_ID-RUN_ATTEMPT` contains `pair-certificate.json`, and `independent-payroll-producer-RUN_ID-RUN_ATTEMPT` contains `independent-producer-result.json`. The pair certificate uses schema version 2 and lane `real-http-synthetic-v2`, with the two tested SHAs, trusted workflow revision, run ID, current attempt, pass results, and the SHA-256 digest of the exact independent result bytes. The consumer verifies the retained result’s candidate SHA, real HTTP and synthetic flags, hours/payroll/receipt totals, independent policy and capabilities, and the fixture/driver hashes against the files at the trusted workflow revision. Schema 1 evidence cannot certify a new deployment; dispatch a new certification after the reviewed schema-2 writer and consumer are installed. Synthetic operator browser evidence is retained separately for 14 days in `connected-manual-browser-RUN_ID-RUN_ATTEMPT`; it is diagnostic evidence, not a substitute for either release artifact. Database dumps, source documents, fixture manifests, secrets, and delegation tokens are not uploaded as artifacts. Certificate artifacts expire after 90 days; recertify when evidence has expired.

The poller examines the latest certification attempt for its exact candidate pair. Missing, pending, failed, cancelled, expired, mismatched, or unavailable evidence holds the current deployment. Independent green workflows do not authorize a pair. A successful certificate for another pair is never substituted. Existing deployed containers are left alone when their recorded pair has not changed; their historical deployment is not retroactively called certified.

Direct deployment enforces the same certificate check before loading secrets or changing containers or data. To bootstrap with a specific successful, retained certificate, supply its GitHub run ID explicitly:

```bash
ops/staging-v2/deploy.sh FULL_PAYROLL_COMMIT_SHA FULL_AIRE_COMMIT_SHA CERTIFICATE_RUN_ID
```

This verifies the provider run's repository, workflow path, dispatch event, staging branch, exact pair, completed success, current attempt, and matching artifact. The successful deployment records `deployed-certificate-run-id` alongside the two deployed SHAs. There is no uncertified bootstrap or bypass flag.

Both certification CI and every direct deployment also verify each candidate's latest exact-SHA staging-v2 push workflow: Payroll Quality and AIRE Staging v2 images. All normal quality jobs and both API/web image publication jobs must have completed successfully in that workflow's current attempt. A successful overall workflow with skipped publication is insufficient. Candidate discovery uses the repository-scoped REST workflow inventory with exact SHA, push event and staging branch filters. It validates the complete inventory and job pages (at most 1,000 records each), chooses the newest exact run, checks the current attempt, and rechecks the run and newest inventory before accepting evidence. Automatic certificate selection inventories runs created within the last 90 days, capturing one UTC cutoff for discovery and its freshness recheck. A recent rerun of an older run can have fresh artifacts but remains outside this automatic creation-date window; select its verified run ID explicitly or dispatch a new certification. It also rechecks its newest matching dispatch; an explicitly supplied run ID retains the operator’s deliberate selection. Repository-labelled diagnostics identify unavailable evidence without printing tokens or response bodies. The verifier reads all job pages; missing, pending, failed, wrong-head, wrong-workflow or unavailable candidate evidence holds deployment. CI runs the shared verifier from its trusted caller revision before starting the synthetic drill. The dispatch workflow revision may differ from the candidate Payroll SHA only because the candidates' own quality and image evidence are independently verified.

Local gate tests use only temporary files and mocked CLIs:

```bash
bash -n ops/staging-v2/*.sh scripts/certify_aire_payroll_integration.sh scripts/local_certification/runtime.sh
python3 -m unittest discover -s ops/staging-v2 -p "test_*.py"
```

## Restoring older rehearsal snapshots

A pair certificate uses empty synthetic databases. It does not certify migration of an older populated rehearsal snapshot. Restore that snapshot and its upload archives into a separately named, isolated rehearsal database/project first, record its source schema versions, and migrate forward using the selected release code. Never run `db:schema:load` over restored data, downgrade immutable history, or rewrite old approvals/cutoffs to make a new policy appear historical. Existing v1 calendars keep their recorded cutoff policy; new regular runs use the separately confirmed current schedule.

AIRE's revision-ledger migration captures current entry snapshots at migration time. It cannot reconstruct unrecorded edits from earlier cutoffs. Preserve finalized batch evidence, report that historical limitation, and require reconciliation before importing affected old time. Its setting-key migration also removes duplicate settings, so retain the original restore source. Payroll refuses to overwrite a partially installed Solid Queue schema; investigate that state rather than loading a destructive replacement. An application-image rollback leaves migrated databases in place and requires known schema compatibility or a reviewed restore/roll-forward plan.

Run database readiness, queue checks, retained-artifact recovery, and source/target reconciliation on the migrated rehearsal. Keep workers and external deliveries disabled until that restored environment is isolated and ready. A successful synthetic certificate does not waive those checks or the named operator and recovery acceptance.

Never point this stack at production data, production Clerk instances, or the existing staging databases and volumes.

The reusable certification workflow sets `AIRE_ACTIONS_PUBLIC_READ=true` for AIRE’s public Actions metadata. The constrained REST reader sends no Payroll token to that repository; Payroll’s own evidence still uses its workflow token. Host deployment checks use the authenticated `gh` path by default. Both paths enforce the same exact revision, latest workflow attempt, quality jobs and API/web image publications, and hold deployment when evidence is unavailable.
