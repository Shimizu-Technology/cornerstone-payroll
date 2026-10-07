/** Guidance supplements the original error; it never clears a payroll blocker. */
export function errorRecovery(message: string): string | null {
  if (/^Calculated \d+ employees?\. \d+ employees? needs? attention/i.test(message)) return null;
  if (/Can only approve a calculated pay period/i.test(message)) return 'Calculate payroll and resolve every employee error, then review the results before approval.';
  if (/Can only commit an approved pay period/i.test(message)) return 'Review the completed calculation and approve the payroll before committing it.';
  if (/new.hire documents|identity and work authorization|signed withholding/i.test(message)) {
    return 'Open the named employee’s record → Manage documents. Attach the required documents and have an authorized reviewer check them. Then return to payroll and try again.';
  }
  if (/historical.*401\(k\).*classification|imported.*401\(k\).*contribution types|retained historical.*review|retained source digest|contribution.type review/i.test(message)) {
    return 'Open the employee’s Pay setup → Yearly retirement checks for this payroll year. Confirm each historical contribution type against the source records and save the review. Then calculate payroll again. Historical tax or filing corrections require their own review.';
  }
  if (/plan permits designated Roth|plan.*(does not offer|Roth.*availability)|verified plan.*(reference|terms)/i.test(message)) {
    return 'Open the employee’s Pay setup → Contribution settings. Check the plan document or administrator’s instructions, confirm which Roth features the plan permits, and record the verified settings. Then calculate payroll again.';
  }
  if (/prior.year.*(wages|wage).*verif|verify.*prior.year.*(wages|wage)|employer wage evidence|wages.*require designated Roth/i.test(message)) {
    return 'Open Pay setup → Yearly retirement checks. Verify the prior-year Social Security wages from this employer using the employer wage record, save its source, and recalculate. Do not enter zero unless you verified there were no covered wages.';
  }
  if (/retirement limits are not configured|annual.*(limits|rules).*(missing|verified|available)|missing.*annual.*(limits|rules)/i.test(message)) {
    return 'Ask a platform administrator to add the verified IRS retirement limits for this payroll year in Tax Configuration. Then calculate payroll again.';
  }
  if (/retirement setup needs review|401\(k\).*reporting group/i.test(message)) {
    return 'Compare the employee’s Contribution settings, recurring deductions, and payroll fields against the verified plan. Keep one source for the same contribution, with the correct tax treatment and reporting group. Then calculate payroll again.';
  }
  if (/date of birth.*(verify|verif|missing)|verify.*date of birth/i.test(message)) {
    return 'Check the employee’s date of birth in Employee details against the source record before saving catch-up settings.';
  }
  if (/client approval|client review.*(required|changed|stale)/i.test(message)) {
    return 'Open the payroll’s client review and obtain approval for the latest calculated revision before approving or committing payroll.';
  }
  if (/workweek.*(missing|configured|confirmed|review)|no legal overtime workweek/i.test(message)) {
    return 'Review the employer’s confirmed seven-day overtime workweek in Pay Schedule Settings, apply it to this run, and recalculate before relying on overtime results.';
  }
  if (/loan.*(balance|authorization|repayment|configuration|review)/i.test(message)) {
    return 'Check Employee Loans and the named employee’s deduction against the loan balance and authorized repayment schedule. Resolve the discrepancy, then recalculate.';
  }
  // Keep useful server-supplied instructions instead of adding generic clutter.
  if (/\b(try again|retry|recalculate|reload|refresh|verify|check|review|choose|add|attach|select|contact|sign in|ask)\b/i.test(message)) return null;
  return 'Check the information for this action. If the message does not identify a field or the problem continues, contact support with the page, action, and this error message.';
}
