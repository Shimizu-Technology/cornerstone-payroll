# staging-v2 → production release checklist

Promotes Cornerstone Payroll `staging-v2` and AIRE Services `staging-v2` to production together. This page is the ordered checklist; the linked documents hold the detailed procedures. Written October 31, 2026.

**Two stages (November 2 correction).** Stage 1 ships certified Payroll `08b5379ec448eda50b86477fcce9e2141686b172` and AIRE `4698a7dc3e6b64af2ab72f2df7c927b2e30c3c07` with connected payroll **paused, without running rollout configure tasks**. Payroll migration `20261024092000` nevertheless persists the immutable Oct 16 boundary; AIRE has no rollout singleton or calendars. The accountant continues manual entry. Stage 2 is held for a separately selected later period and a newly reviewed/certified pair; see [the Stage 2 procedure](integrations/aire-history-packet.md). Claude is the only merge owner for the held implementation PRs.

**Do not start the release window while any payroll is mid-process** (calculated but not committed, or checks being printed) in either app.

## Owners

| Role | Who | Decides |
|---|---|---|
| Release owner | Leon | Go/no-go, runs deploys and commands |
| Accounting reviewer | Chels (Mark for Spike/MoSa/DDG questions) | Approves FICA recovery plans, source reviews, check-void classification |
| Tax tables | Cornerstone CEO | Verifies 2027 withholding tables before the first 2027 payroll. Nobody else marks a year verified. |

## 1. Before merging (the day before)

Production auto-deploys from `main`, so everything here must be done before any merge.

- [ ] **Staging acceptance.** Chels signs off on staging running the final release SHAs (manual payroll, AIRE import, already-paid AIRE history reconciliation, manual Lock on an unpaid fixture, reports Mark uses). October 1–15 is already paid by #94; do not publish/Lock it again on the production-copy rehearsal.
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
  
  - Form 941 line 7 now uses the IRS fractions-of-cents method, so lines 7, 10 and 12 move by a few cents: Cornerstone +$0.02, AIRE +$0.07, Spike −$0.04, MoSa +$0.10. Tell Chels in case Q3 was filed from the old screen.
  - AIRE employee 15's $66 W-4 additional withholding (Mar 30, Apr 16 and May 15) now counts in the deposit totals and the YTD summary. Chels confirms the Q1 deposit and W-1 included $66, and the Q2 ones $132.
  - Voided runs show $0, and the FIT columns are split into base, additional and total (same amounts).

  Anything else is a stop.
- [ ] **Background backlog.** List pending Solid Queue jobs in production (invoice emails, reminders, tax sync, OCR, invites). They resume when the new workers start. Decide whether each should run.
  - The November 2 copy had none ready or scheduled.
  - It had 168 **failed** jobs from April to September: 155 are `AirePayrollAcknowledgementDispatchJob` missing-table errors, plus OCR and process-pruned failures. Failed jobs never rerun on their own, so leave them or discard them after the release.
  - 21 committed periods (Cornerstone 4, AIRE 4, Shimizu 1, Spike 12; January to May) have failed Cornerstone Tax sync with 0 attempts. Nothing retries them. Use `retry_tax_sync` only if Cornerstone Tax needs those months.
- [ ] **Backups.** Take a paired restore point of both production databases immediately before the window. Several migrations can't be reversed, so this is the real fallback.

## 2. Release window

Follow [AIRE manual-to-scheduled lock rollout](integrations/aire-lock-rollout.md) for the detailed lock steps.

1. [ ] Stop or drain the old Payroll publishing/delivery workers and AIRE finalization workers. Old code doesn't know about the pause switch.
2. [ ] **AIRE first.** Merge AIRE `staging-v2` → `main`, deploy manually, and confirm migrations ran. Then:
   ```sh
   bin/rails connected_payroll:status          # expect mode: paused
   ```
3. [ ] **Payroll second.** Merge Payroll `staging-v2` → `main`, deploy web and worker manually. Migrations run in the web predeploy (`db:safe_prepare`). Then for each AIRE source:
   ```sh
   bin/rails connected_payroll:status          # expect mode: paused, on web and worker
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
   - **Data fix in production before MoSa's next payroll** (supported UI only): add Zachary Camacho's 4% Roth election. In MoSa's Hotbox, Inc., open Employees → Zachary Camacho → Pay setup → **Set up retirement**, then:
     - set the first pay date using the election, and enter the plan source reference (MoSa's plan permits Roth; QuickBooks "401(k) After Tax" 4% through 2026-07-30);
     - check **Plan permits employee Roth deferrals**, with Roth at 4%;
     - for the employer match, either check **Administrator confirmed employer Roth support** or set the destination to Traditional.

     Until the election exists, the new code refuses to calculate his paycheck. He has had no paid hours since July 30, so no contributions were missed.
   - **Monique Amani needs no correction.** Her $927.91 pre-tax 401(k) and 4% match were deducted on every Cornerstone check through a payroll-field deduction (verified in production 2026-11-02, and recalculated correctly on staging).
   - Recalculate every unfinished run before approval.
   - `bin/rake payroll:legacy_employer_benefits:inventory` should report no affected employees (it found none on the staging copy).
   - Data added after October 25 (for example Kasperbauer) is covered by the fresh inventory the runner takes; Kasperbauer's history is recorded later with the prior-provider history feature, not here.
   - **Kasperbauer's 20 calculated runs (Jan 14 – Oct 28) are prior-provider history.** Never approve, commit or delete them. After the release they show "Recalculate — lacks annual context verification"; that is expected. They are converted with the prior-provider history feature (#407) after the release.
6. [ ] **Access.** Grant Chels "Client management" for each client she will run.
7. [ ] **Smoke test while paused:**
   - AIRE: clock in and out, edit an entry, approve it.
   - Payroll: open a manual client, print a pay stub, the register, and the Q3 941 and W-1. Line 5 of the W-1 should be filled, and amounts should sit on 941 lines 6 and 10.
8. [ ] **Stop Stage 1 here.** Verify both fleets remain paused, neither rollout configure task was run, AIRE has no rollout singleton and no connected calendar was published. Payroll’s migration-default Oct 16 boundary remains present. Keep entering AIRE hours by hand. Do not run the AIRE paid-history or Payroll historical approval commands as part of Stage 1.
9. [ ] **Stage 2 is separately held.** After its implementation is reviewed, the exact pair is certified and a fresh contained rehearsal passes, Leon/Chels choose the first connected period. Follow [the ordered maintenance and packet procedure](integrations/aire-history-packet.md): configure later boundaries and reconcile manual history while paused; enable both fleets **unpublished**; pin/link/map; export/review/preview/apply/fresh completion; only then publish and route genuinely owed hours.
13. [ ] Decide whether to turn production auto-deploy back on.

## 3. After the release

- [ ] Chels verifies October 1–15 remains recorded as already processed against paid run #94. Do not run another manual Lock or connected import for those wages. Reconcile any genuine correction through the settlement-case/evidence workflow.
- [ ] Keep connected payroll paused after Stage 1. Stage 2 selects and verifies its own adjacent-period payday and future cutoff before publication.
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
