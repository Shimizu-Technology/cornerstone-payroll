# Retirement limits and evidence

This implementation supports standard 401(k) payroll with a calendar limitation year. It computes and records contributions and liabilities; the retirement administrator owns plan qualification, nondiscrimination testing, allocation, remittance acceptance, and applicable Form 1099-R reporting. Non-calendar/short years, other plan types, and unresolved related-plan structures require administrator review before automatic participation.

## Verified rules

[IRS Notice 2025-67](https://www.irs.gov/pub/irs-drop/n-25-67.pdf) sets the 2026 regular elective-deferral limit at $24,500, ordinary catch-up at $8,000, enhanced age-60-through-63 catch-up at $11,250, annual additions at $72,000, and employer contribution compensation at $360,000. The $150,000 wage threshold applies to 2025 sponsoring-employer covered Social Security wages for 2026 Roth catch-up treatment; exactly $150,000 does not exceed it. Future yearly values must be verified and entered, never copied from illustrative regulation examples.

Age is attained by calendar year end: ages 50–59 and 64+ have a $32,500 employee ceiling; ages 60–63 have $35,750, if the plan permits catch-up. Traditional and designated Roth elective deferrals share the personal ceiling. Genuine non-Roth after-tax contributions are separate and cannot satisfy Roth catch-up. [Contribution types](https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-contributions)

Catch-up can arise from the statutory elective limit, a verified lower regular plan limit, or the annual-additions limit. Earlier local designated Roth elective deferrals can satisfy required Roth catch-up; outside Roth deferrals and rollovers do not establish this sponsoring employer's Roth compliance. Automatic conversion of a Traditional election to Roth is not assumed. [Catch-up eligibility](https://www.irs.gov/retirement-plans/issue-snapshot-401k-plan-catch-up-contribution-eligibility), [final regulations](https://www.irs.gov/irb/2025-40_IRB)

Annual additions include applicable employee, employer, and non-Roth after-tax contributions, excluding valid catch-up, and cannot exceed the lesser of the statutory dollar amount and applicable compensation. Required employer matching is never silently reduced to hide a limit conflict. Retroactive reclassification of already committed deferrals requires administrator review. Employer matching uses capped eligible compensation; the compensation ceiling does not automatically stop employee deferrals from later wages. [Annual-additions controls](https://www.irs.gov/retirement-plans/fixing-common-plan-mistakes-failure-to-limit-contributions-for-a-participant), [compensation and matching](https://www.irs.gov/retirement-plans/401k-plans-deferrals-and-matching-when-compensation-exceeds-the-annual-limit)

The ordinary Roth catch-up requirement applies in 2026 after the transition period ended. The detailed final framework generally applies from 2027 and permits earlier application. Special governmental, collectively bargained and Puerto Rico provisions require plan-specific review. [IRS implementation announcement](https://www.irs.gov/newsroom/treasury-irs-issue-final-regulations-on-new-roth-catch-up-rule-other-secure-2point0-act-provisions)

## Staff workflow

1. In **Tax Configuration**, a platform administrator verifies and saves all six yearly limits, an official HTTPS IRS source, and a reason. Staff can read annual limits. Test workspaces cannot edit shared limits.
2. In **Employee → Pay setup → Retirement plan**, a client configuration administrator records a dated election, contribution amounts, catch-up permission, eligible compensation, and matching. Verify DOB and the plan/provider reference for catch-up or Roth features. Blank optional caps mean no additional cap; an explicit zero means zero capacity.
3. In **Annual retirement evidence**, select the payroll year and record verified prior-year employer wage evidence. Unknown wages stay unknown; an explicit verified-zero/no-prior-employer-wages record is different. Capture applicable outside elective deferrals separately from sponsoring-employer wage evidence. Include only plans sharing the personal 402(g) ceiling; 457(b), employer additions, rollovers and non-Roth after-tax amounts do not belong in those outside-deferral fields.
4. Opening amounts supplement saved payroll and historical bridge records. Verify that employer additions, applicable compensation and non-Roth after-tax balances are not counted twice. The evidence record and review note are append-only; corrections create another review.
5. Recalculate affected editable payroll. Review the saved election, wage evidence, complete employee ceiling, catch-up used, remaining capacity and annual additions on the paycheck. Insufficient cash reduces discretionary deductions, then recalculates applicable taxable wages and matching. Mandatory taxes are preserved; unresolved cash or contribution conflicts block processing with a review message.

The year-end preview is informational. Paychecks use their actual pay-date election. A first future election preserves the existing legacy setup before its effective date. New rule snapshots retain annual rules, DOB/age, YTD baseline and evidence for later replay; old snapshots retain their original evidence limits.

Catch-up is a plan permission and statutory classification, not a separate extra limit created by naming a column “catch-up.” Adding a second field adds another requested contribution. Paused recurring assignments can leave saved manual paycheck entries active; the worksheet identifies these retained entries and links to the paycheck for review. Requested and applied amounts are shown separately. Unchanged worksheet saves retain the original request, while an explicit new amount or zero replaces it. Clear an obsolete manual request before configuring a replacement, and preserve committed history.

## Rollout and operational acceptance

The additive migration introduces annual-additions/compensation limits and append-only annual evidence. It completes the published 2026 rule row and preserves saved paycheck history. It does not fabricate signed plan terms, prior-year wages, or external contributions for existing employees. Before affected current payroll, staff must verify legacy/dated Roth support and catch-up evidence, including imported labels that say only “After Tax.” Use **Roth 401(k)** for designated Roth and **401(k) non-Roth after-tax** for genuine after-tax additions.

Employer designated Roth contributions require documented plan/provider support, applicable vesting, and a provider reporting handoff. They generally use Form 1099-R rather than employee W-2GU code AA; payroll check date alone does not establish plan allocation year. [IRS reporting guidance](https://www.irs.gov/newsroom/secure-2-point-0-act-impacts-how-businesses-complete-forms-w-2)

Local synthetic verification and deployment health do not certify an employer's plan or fund a retirement account. Operational acceptance requires the employer/administrator to confirm source records, plan terms, output totals and remittance/reporting ownership. Guam's mirror-income-tax framework is established by [48 USC 1421i](https://www.govinfo.gov/link/uscode/48/1421i).

## Verification record

The local review uses disposable PostgreSQL databases and company/employee fixtures, with no production payroll mutations. Focused regressions cover age/birthday boundaries, exact wage threshold, missing annual rules and evidence, outside deferrals, non-Roth after-tax additions, employer matching and compensation, unavailable Roth, zero caps, year rollover, historical replay, final available-pay tax/match reconciliation and authorization. Mobile and desktop computer use verifies actual staff saves; browser tests retain responsive workflow coverage.

Deployment is Git-driven from main: Render API/worker plus Netlify frontend. Verify the merged commit on all three and the migration/health outcome. The task does not use staging or staging-v2 branches.
