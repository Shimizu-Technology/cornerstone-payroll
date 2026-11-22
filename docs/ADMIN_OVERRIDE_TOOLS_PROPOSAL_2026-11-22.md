# Admin override tools: proposal

**Status:** Idea, parked. Leon asked on November 22, 2026 to record this and revisit it after Milestone 3. Nothing here is decided or scheduled.

## The problem

Payroll is strict on purpose, and that has mostly worked. But a few times a run, a calculation or a locked step needed to change and the app had no way to do it. Each time, someone worked around it with a direct database fix, a one-off script or a manual step outside the app.

Leon compared this to his Salesforce admin role at Bank of Guam. When a closed service request has to be reopened, people message him, and only the system admin can do it. The question is whether Payroll should have something similar: an admin-only way to undo, roll back or override.

## Why payroll can't just "reopen"

Reopening a closed Salesforce case only changes Salesforce. Committing payroll creates facts outside the app:

- checks are printed with check numbers
- the direct-deposit file goes to the bank, or employees are paid
- tax deposits and filings go to the IRS and Guam DRT (941, W-2GU)
- year-to-date totals feed the W-2s

If a run could simply be un-committed, Payroll would disagree with the bank, the tax agencies and the employee's pay stub. Large payroll providers such as ADP don't reopen finalized payroll for this reason. They correct it with offsetting entries: void and reissue, adjustment or corrective checks, and amended filings.

Payroll already has several of these correction tools: void and reissue, corrective paychecks, reversed paychecks and pay-period corrections. Some past workarounds may have been cases where a tool existed but was hard to find. Others are real gaps.

## Recommendation

### 1. Start from real cases

Before building anything, list every past workaround. Sources are git history, operator notes, direct database fixes and support threads. Known examples include:

- the Kasperbauer historical runs and their approval failures
- the MoSa run 132 data fix
- one-off production scripts run during releases

For each case, record what happened, what the app refused, what the workaround was, and whether an existing correction tool would have handled it. The result splits into two lists:

- **Make an existing tool easier to find or use.**
- **A real gap**, which becomes a specific override action.

### 2. Specific, audited override actions, not a free-form editor

A general "edit anything" tool would bypass the rules that keep history, year-to-date totals, pay-rate history and the audit trail correct. Each override should be one named action that keeps those rules intact. Candidates, to be confirmed by the case list:

| Action | When it's allowed | When it isn't |
|---|---|---|
| Reopen a pay run | Committed or approved, but nothing has left the building: no checks printed, no deposit file sent, nothing filed | Anything already issued or filed. The action points to void and reissue or a corrective run instead |
| Override a calculated amount | One line, such as a tax or deduction, with a reason | — |
| Unlock a locked step | A cutoff, an approval gate or a document-readiness gate, with a reason | — |
| Re-run a stuck job or import | A failed or stuck background job or import | — |

Each override shows on the record itself, for example "Overridden by Leon on Nov 22: reason". That marker appears on the pay stub, the register and the reports where it matters.

### 3. The same safeguards on every override

- **Who:**
  - Super admins can use every action.
  - Org admins get only the actions Leon enables for them, within their own organization. Today the org admins are Chels and possibly Dafne.
  - Client users and employees never get override actions.
- **A required reason,** and a before-and-after record kept permanently in the audit log.
- **A notification** to Leon and Dafne whenever one is used.
- **Optional for the riskiest actions:** a second approver, so it takes two people.
- **Time-boxed** where it makes sense, for example an unlock that expires after the fix.

### 4. When to build it

After Milestone 3. It depends on two Milestone 3 pieces:

- **M3-3, non-staff audit actors:** every override needs a complete audit actor.
- **M3-4, effective-dated pay and locked periods:** "approved and committed periods are locked" is the rule an override has to step around safely.

It could open Milestone 4 or be a small milestone of its own. Step 1, the case list, is read-only research and could start earlier.

## Open questions for Leon

1. Which actions should org admins get, if any?
2. Which actions need a second approver?
3. Should overrides be visible to client offices, for example "This paycheck was corrected by Cornerstone"?
4. Is a time-boxed unlock useful, or is "reason plus audit" enough?

Related: [Milestone 3 build plan](MILESTONE_3_FOUNDATIONS_BUILD_PLAN_2026-11-22.md) and [product architecture decision](PRODUCT_ARCHITECTURE_DECISION_2026-11-19.md).
