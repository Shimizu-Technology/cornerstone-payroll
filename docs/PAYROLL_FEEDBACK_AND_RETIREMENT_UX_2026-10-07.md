# Payroll feedback and retirement setup

Payroll staff need to see the outcome of an action immediately, understand what needs attention, and keep their entered values while resolving it. The interface uses the existing Cornerstone styling and supports phone and desktop widths.

## Retirement workflow

Contribution settings describe each paycheck's planned Traditional and Roth deductions, its first effective pay date, participation, and employer contribution. The combined planned amount is explicit; annual limits and available pay can reduce the final deduction. Enabling catch-up increases the annual allowance. It does not add a second deduction or change the entered amounts.

Yearly checks describe the records used for annual limits: imported contribution classifications, applicable prior-year employer Social Security wages, outside-employer deferrals, and additional opening balances absent from saved payroll. They preserve the distinction between unknown wages and verified zero. Clearing a verified wage amount leaves it blank and prevents saving until an explicit amount is entered. Optional balances and special plan limits remain under disclosures.

Roth catch-up guidance applies from 2026, when the applicable prior-year covered employer wage threshold is exceeded. Regular Traditional contributions remain permitted. The interface does not apply that requirement to earlier years or present a nonparticipating employee's wage check as immediately required. See the [IRS catch-up explanation](https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-catch-up-contributions) and [employee contribution limits](https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-contributions).

Plan permissions, employer Roth support, eligibility, evidence, and historical confirmation requirements remain enforced. Imported paid checks and historical tax filings are not rewritten by a contribution-type review. A missing review now says it is missing; a changed source digest remains a separate error.

## Action feedback

Transient errors, successes, and action notices use the shared top viewport. Errors and warnings stay until dismissed or their source resolves. Success and information messages remain for ten seconds, with the timer paused while hovered or focused. Success survives navigation within the same user/client context; changing user, organization, or client clears feedback. Late notifications captured under an old client cannot overwrite the new client's feedback.

Field validation, loading/retry screens, persistent compliance warnings, and detailed import results retain their local context. Confirmation dialogs remain intact. Toasts use live status/alert semantics, reduced motion, keyboard-accessible controls, bounded phone widths, and coordination with modal focus/inert handling. See [W3C status messages](https://www.w3.org/WAI/WCAG21/Understanding/status-messages).

For new code, use `useFeedback().notify` for imperative outcomes such as a save followed by navigation. Use `ActionFeedback` for existing state-driven outcomes. Pair error state with `useFeedbackState` and pass its third value as `retryKey`; this lets an identical failed attempt reappear after dismissal without clearing the underlying validation state.

API decoding preserves status and response data, humanizes validation fields, and supplies recovery for session, permission, concurrency, size, network, and server failures. It does not infer that a successful HTTP response means every employee calculated.

## Payroll calculation errors

A calculation with employee failures shows a short toast and a grouped, named issue list. Matching retirement failures link to the correct employee section and payroll year. Review links open a separate tab so the original worksheet retains unsaved failed inputs. Staff resolve the issue, return to the original payroll tab, and calculate again. Shared missing IRS rules identify the platform-administrator action rather than sending staff through individual contribution changes.

A failed recalculation of an earlier complete run now invalidates that calculation, supersedes its prior review, and persists Draft status. Approval remains unavailable after refresh or through a direct API request until a full calculation succeeds. Unsaved failed new-paycheck association targets are discarded before parent invalidation, preserving the existing rollback behavior. The activity history retains the attempt; the draft timeline labels it as a calculation attempt.

There are no database migrations or changes to saved elections, percentages, contribution types, annual IRS values, or existing document reviews in this rollout.
