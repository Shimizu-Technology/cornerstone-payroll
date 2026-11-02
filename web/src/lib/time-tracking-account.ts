export const TIME_TRACKING_CONNECTION_MESSAGE = 'Connect your time tracking account to review AIRE hours for this payroll.';

export function needsTimeTrackingAccount(message: string | null): boolean {
  return Boolean(message && /X-Aire-Delegation-Token|delegation token|connect your (?:AIRE|time tracking) account/i.test(message));
}
