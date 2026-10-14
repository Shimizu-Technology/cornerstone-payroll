# Workspace entry-point review

An accountant assigned as a reviewer could see the read-only workspace banner but still see Add employee on the dashboard and New Pay Period, Edit, Delete, Recalculate, and Approve on the payroll list. Server authorization and the employee/workspace detail guards prevented writes. The entry points nevertheless directed the reviewer toward actions they could not complete.

Dashboard and PayPeriods now use the same effective company-write permission as the record workspaces. Reviewer, expired, archived, sealed, and backup workspaces offer review destinations. An opened create/edit draft stays in memory during temporary access loss; its dialog and submit action return only when write access returns. Handlers also check the current permission before requesting a mutation.

The check workspace had the opposite problem: it described the VOID rehearsal PDF but hid its read-only preview from reviewers. Calculated and approved rehearsal runs now allow that preview when a positive-net paper check is available. Official printing, processing, and payment-method changes retain their existing write guards. Previewing never assigns a number, marks a check printed, or issues a payment.

## Validation so far

Root used native Chrome in the existing Code School profile after the T3 automation host explicitly became unavailable. The private API used normal database accounts and the existing test identity header, a test job adapter, and loopback-only transport. External authentication and physical printers are separate acceptance dimensions.

The starting combined API was `f2d7748224488551d36e01fbf3e7c2b80a9ab216`. With this repair, 40 focused frontend checks and the full 94-file/831-test frontend suite passed. Strict lint passed. The first production-build check caught an overbroad TypeScript cast in a new test; the corrected fixture compiles and the production build passes. The final stacked and integrated head still needs its release checks.

Actual reviewer acceptance in private `payroll_combined_qa_20261014`:

- User2 selected sandbox2; the banner explained read-only access and retained the live-source company context.
- Employee creation resolved to the read-only guard, without a save form. Payroll overview and detailed item links remained available without processing controls.
- After the repair, the 390×844 payroll card offered View and Read only, without list mutations. The phone dashboard offered Browse Pay Periods and Browse Employees without Add employee/Create pay period.
- The reviewer opened the real VOID rehearsal PDF, visually reviewed the desktop and phone modal, and downloaded it. Item1 retained its exact original update timestamp, no check number, zero print count, and null printed/prepared timestamps.

The rehearsal fixture contains saved aggregate deductions without matching factory component fields. Its PDF validates access, watermark, and absence of payment writes; it is not the tax-arithmetic oracle. Separately calculated reporting fixtures provide that arithmetic coverage.

Remaining acceptance before staging release: final combined desktop/phone access checks across reviewer/operator/manager/workspace administrator and sealed/expired records; complete reporting and connected Source journeys; final exact-head review, engineering gates, and paired staging deployment verification. No staging-ready or production-ready claim is made by this component report.
