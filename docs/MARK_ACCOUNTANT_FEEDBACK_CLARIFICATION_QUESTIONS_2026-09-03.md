# Mark accountant-feedback clarification questions

**Prepared:** September 3, 2026 (Guam, UTC+10)

**Audience:** Mark and Cornerstone leadership

**Purpose:** Confirm the intended accountant workflow before Shimizu Technology changes payroll behavior or introduces new compliance rules

The questions below are deliberately separated from implementation. Existing behavior should remain unchanged until Cornerstone answers the applicable section.

<!-- markdownlint-disable MD029 -->
<!-- Question numbers are stable identifiers across sections and intentionally do not restart at 1. -->

## Payroll register and names

1. Which screen or output were you using when you wanted separate first- and last-name columns: the live Employee Payroll table, the payroll-register preview, the PDF, the CSV/Excel export, or all of them?
2. Should the on-screen order be `Last Name | First Name` or `First Name | Last Name`?
3. Which columns should have totals in the live Employee Payroll table? Should non-money fields such as rate and check number remain blank in the totals row?

## Medicare presentation

4. Where should Medicare be separated: the live payroll table, register preview, PDF, CSV/Excel export, transmittals, or every accountant reconciliation surface?
5. Do you want three explicit values—employee regular Medicare, employer Medicare, and employee Additional Medicare—or only employee versus employer Medicare?
6. Should the Additional Medicare column remain visible when every employee has a zero amount?

## Pay-stub access

7. Where were you working when the pay stub was difficult to find?
8. The committed Checks & Payments view already supports individual and batch print/download. Is that workflow sufficient if the labels are clearer, or should pay stubs also be available from the payroll row and employee profile history?
9. Should the primary action open a preview, print immediately, or download the PDF?

## Accountant activity history

10. Which events should accountants see: payroll calculation/approval/commit only, or also employee changes, imports, checks, reports, payroll fields, loans, and corrections?
11. Should accountants see detailed before-and-after values, or only who performed the action and when?
12. Is CSV export required for the company-scoped accountant view?

## Straight and installment loans

13. Does a “straight loan” mean a fixed deduction that continues until someone manually stops it, or a deduction with a known end date but no balance tracked in this application?
14. Is the deduction always repayment to the employer, or can it be payable to another person or organization?
15. Can one employee have multiple active loans? If so, how should imported amounts be matched to a specific loan?
16. Can installment loans include interest, fees, or new advances after the original amount?
17. If available net pay cannot cover the scheduled loan payment, should the system take a partial payment, take nothing, or require an accountant decision?
18. For imported installment loans, which balance is authoritative: Cornerstone Payroll's ledger or the client workbook's beginning balance?
19. Should committing payroll automatically reduce the loan balance, or should an accountant confirm imported loan activity first?

## 401(k) catch-up

20. Which plans must be supported: traditional 401(k), Roth 401(k), or another plan type?
21. Which catch-up eligibility rules apply to Cornerstone's clients, including whether enhanced age-based rules are needed?
22. Does employer matching apply to catch-up contributions, and does bonus pay belong in the deferral base?
23. When a client starts midyear, what source is authoritative for prior-year-to-date employee deferrals?
24. At the annual limit, should the system automatically take a partial final deduction and stop future deductions?
25. Who may override a limit or eligibility result, and what approval or recorded reason is required?

## Child support

26. Does Cornerstone want a controlled manual workflow—where the accountant enters an approved amount and verifies legal limits—or a full compliance engine that calculates withholding limits and order priority?
27. Which jurisdictions and order types must be supported?
28. Can an employee have multiple orders, arrears, administrative fees, or competing garnishments?
29. How should insufficient disposable earnings be allocated among multiple orders?
30. Does Cornerstone remit by individual check, combined agency check, or electronic payment?
31. What confirmation number, receipt, allocation, and proof-of-payment records must be retained?

## Payroll approval controls

32. May the same accountant calculate, approve, and commit a payroll, as the system allows today?
33. If a second person is required, must they approve only, or must a separate person also commit?
34. May a manager or organization administrator override the separation rule in an emergency? If so, what reason and audit evidence are required?

## Recurring employee defaults

35. Is the deployed behavior—refreshing non-overridden draft/calculated payroll when payroll is recalculated—sufficient?
36. Should saving a recurring employee-profile change show every open payroll affected and require an explicit `Apply to open payroll` confirmation?
37. When one recurring item changes, should an accountant be able to preserve other period-specific adjustments while applying only that changed item?

## Decision record

For each section, record the answer, the person who approved it, and the effective date before implementation begins. Tax-limit, retirement, garnishment, or child-support rules also require confirmation against the applicable current authority; product copy must not imply that a generic deduction field is a compliance engine.

<!-- markdownlint-enable MD029 -->
