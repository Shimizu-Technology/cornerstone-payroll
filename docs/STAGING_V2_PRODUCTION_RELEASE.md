# staging-v2 → production release checklist

Promotes Cornerstone Payroll `staging-v2` and AIRE Services `staging-v2` to production together. This page is the ordered checklist; the linked documents hold the detailed procedures. Written October 31, 2026.

**Deadline:** finish before **November 7, 2026, 17:00 ChST**, the first automatic AIRE hour lock (October 16–31, paid November 15). If the release slips past that, move the lock start date to the next period first; don't run a late release with a lock start date that has already passed.

**Do not start the release window while any payroll is mid-process** (calculated but not committed, or checks being printed) in either app.

## Owners

| Role | Who | Decides |
|---|---|---|
| Release owner | Leon | Go/no-go, runs deploys and commands |
| Accounting reviewer | Chels (Mark for Spike/MoSa/DDG questions) | Approves FICA recovery plans, source reviews, check-void classification |
| Tax tables | Cornerstone CEO | Verifies 2027 withholding tables before the first 2027 payroll. Nobody else marks a year verified. |

## 1. Before merging (the day before)

Production auto-deploys from `main`, so everything here must be done before any merge.

- [ ] **Staging acceptance.** Chels signs off on staging running the final release SHAs (manual payroll, AIRE import, the October 1–15 manual lock, reports Mark uses).
- [ ] **Final pair certificate.** The `quality.yml` exact-pair certification has passed for the exact Payroll and AIRE `staging-v2` SHAs you will merge. Re-run it if either branch changes:
  ```sh
  gh workflow run quality.yml --repo Shimizu-Technology/cornerstone-payroll --ref staging-v2 \
    -f payroll_sha=<payroll staging-v2 SHA> -f aire_sha=<aire staging-v2 SHA>
  ```
- [ ] **Turn off auto-deploy** on the production Render services: Payroll web `srv-d74hd8v5r7bs73ctg8a0`, the Payroll worker, and AIRE `srv-d76a676dqaus73csasm0`. The merge then won't deploy on its own, and you choose the moment.
- [ ] **Production backend settings** on Payroll web, Payroll worker and AIRE web:
  - `DEPLOYMENT_ENV=production` (the new code refuses to boot without it)
  - `CONNECTED_PAYROLL_MODE=paused` (production also pauses when this is unset, but set it explicitly)
- [ ] **Production frontend settings** on both production Netlify sites: `DEPLOYMENT_ENV=production` and `VITE_DEPLOYMENT_ENV=production`. Without them the build fails safely and the old site stays up.
- [ ] **Migration rehearsal.** Branch both production Neon databases, run the migrations against the copies, and record the times. On the October 25 copy the total migration run time was about 23 s for Payroll (37 migrations) and 16 s for AIRE (22 migrations); lock waits were not measured.
- [ ] **Manual-client comparison** on that copy: for Spike, active MoSa, Cornerstone and DDG, compare the payroll register, YTD summary and Q3 941/W-1 before and after. Expected differences:
  - Rounding: some gross/net amounts move by a cent (for example $0.21 → $0.22) to match the saved earnings lines.
  - Voided-check inclusion: historical reports change wherever a paper check was voided but the wages were really paid.
  
  Anything else is a stop.
- [ ] **Background backlog.** List pending Solid Queue jobs in production (invoice emails, reminders, tax sync, OCR, invites). They resume when the new workers start. Decide whether each should run.
- [ ] **Backups.** Take a paired restore point of both production databases immediately before the window. Several migrations can't be reversed, so this is the real fallback.

## 2. Release window

Follow [AIRE manual-to-scheduled lock rollout](integrations/aire-lock-rollout.md) for the detailed lock steps.

1. [ ] Stop or drain the old Payroll publishing/delivery workers and AIRE finalization workers. Old code doesn't know about the pause switch.
2. [ ] **AIRE first.** Merge AIRE `staging-v2` → `main`, deploy manually, and confirm migrations ran. Then:
   ```sh
   bin/rails connected_payroll:status          # expect mode: paused
   bin/rails payroll:configure_lock_rollout STARTS_ON=2026-10-16 ACTOR='<name>' REASON='Approved October lock rollout'
   ```
3. [ ] **Payroll second.** Merge Payroll `staging-v2` → `main`, deploy web and worker manually. Migrations run in the web predeploy (`db:safe_prepare`). Then for each AIRE source:
   ```sh
   bin/rails connected_payroll:status          # expect mode: paused, on web and worker
   bin/rails aire_lock_rollout:configure SOURCE_ID=<id> STARTS_ON=2026-10-16 ACTOR='<name>' REASON='Approved October lock rollout'
   ```
4. [ ] Confirm both Netlify production builds from the new `main` succeeded.
5. [ ] **Legacy reviews** (Payroll, accounting reviewer present). Use the release runner in [`ops/payroll-release-day`](../ops/payroll-release-day/README.md). It previews first, refuses to apply without the reviewed preview digest, and fails loudly if anyone is still held. It was rehearsed end to end on the staging copy of production (October 25 data); the steps took seconds each.
   - **Inputs:** companies Cornerstone, AIRE, older MoSa, Spike, active MoSa and Sweep; an authorized admin actor; tax year 2026, coverage through 2026-12-31; external wage bounds $0. Leon confirmed on 2026-10-31 that no 2026 wages were paid outside Payroll un-imported, and that the Spike/AIRE re-runs and voids were handled properly.
   - **What it does, in order:**
     - Applies the reviewed legacy FICA recovery plans (staging copy: Cornerstone 2, older MoSa 49 proofs).
     - Records one $0 source review per held employee (staging copy: Cornerstone 4, AIRE 25, Spike 15, active MoSa 9). This unblocks calculation only; each employee's history and filing review stays open.
     - Reconciles QuickBooks-imported paychecks for active MoSa (staging copy: 109 proofs; 44 checks differed from the computed tax by at most $0.01, which is accepted and recorded).
   - **Run it twice if asked:** after the source reviews, the imported-paycheck plan changes, so the first apply can stop with `Imported FICA plan changed`. Preview again, review the new digest, and apply again. The final preview must exit 0 with zero held employee-years for every selected company.
   - **Reverse AIRE paycheck 289** (Leon approved 2026-11-01): the $175 contractor intern check in the Apr 16–30 payroll was voided because it was never issued and the intern should not have been in that payroll. Reverse it with `ReversePaycheckService` (reason recorded); its year-to-date gross must drop by exactly $175. Then `bin/rake payroll:legacy_check_voids` must list no candidates.
   - **Data fixes in production before or right after the release** (supported UI only): Zachary Camacho's missing 4% Roth retirement election (MoSa), Monique Amani's missing pre-tax 401(k) election (MoSa; four paychecks took $0 since go-live and need an accounting correction). Then recalculate every unfinished run before approval.
   - `bin/rake payroll:legacy_employer_benefits:inventory` should report no affected employees (it found none on the staging copy).
   - Data added after October 25 (for example Kasperbauer) is covered by the fresh inventory the runner takes; Kasperbauer's history is recorded later with the prior-provider history feature, not here.
6. [ ] **Access.** Grant Chels "Client management" for each client she will run.
7. [ ] **Smoke test while paused:**
   - AIRE: clock in and out, edit an entry, approve it.
   - Payroll: open a manual client, print a pay stub, the register, and the Q3 941 and W-1. Line 5 of the W-1 should be filled, and amounts should sit on 941 lines 6 and 10.
8. [ ] **Activate the connection.**
   - Review any overdue scheduled cutoffs first; they become eligible immediately.
   - Set `CONNECTED_PAYROLL_MODE=enabled` on AIRE and Payroll (web and worker).
   - Restart both promptly, so neither app is left enabled alone.
   - `connected_payroll:status` should show enabled on both.
   - Pending AIRE events should drain and receipts arrive.
9. [ ] Decide whether to turn production auto-deploy back on.

## 3. After the release

- [ ] Chels processes October 1–15 through the connected flow if it isn't already paid, using the manual Lock in Payroll.
- [ ] Watch the first automatic lock on **November 7 at 17:00 ChST** and the November 15 payroll.
- [ ] Before the first 2027 payroll, the CEO verifies the 2027 tables.

## If something goes wrong

- **First move:** set `CONNECTED_PAYROLL_MODE=paused` on both apps and restart them. That stops cross-app delivery and automatic locking. Manual payroll and time tracking keep working.
- **Don't redeploy the old `main`.** Its code doesn't understand the new data, and several migrations can't be reversed. Prefer a forward fix.
- **Restoring the backup** after real payroll was issued requires accounting reconciliation, and it can't undo payments already made.

## Known follow-ups (not release blockers)

- An employee with a linked predecessor record in the same company who is near the Social Security wage base can have predecessor wages missed by the ordinary annual FICA path. This predates staging-v2. Check before any such employee nears $184,500.
- Older MoSa (inactive) has six calculated, never-approved runs (June–September), and 13 of its employees would be held for Roth plan verification. Only matters if that company runs payroll again.
- `InvoiceSendSchedule` and `HistoricalClientBootstrapDispatch` hold session advisory locks, which are unreliable through Neon's transaction-mode pooler (the same problem fixed for payment transitions in #409). Move them to the dedicated-connection lock.
- Kasperbauer: merge the prior-provider history feature (#407) after the release, then record their 2026 history before their first Cornerstone payroll.
- Before January W-2s: enter missing SSNs and addresses (AIRE, Cornerstone, MoSa); the CEO verifies the 2027 tax tables.
- Small performance items in the below-threshold FICA path (duplicate review-note query; per-employee snapshot evaluation).
