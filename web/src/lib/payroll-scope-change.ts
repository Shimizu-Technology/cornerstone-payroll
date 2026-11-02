export const PAYROLL_SCOPE_CHANGE_EVENT = 'payroll:before-scope-change';

/** Scope changes must be accepted before API headers or provider keys change. */
export function confirmPayrollScopeChange(): boolean {
  return window.dispatchEvent(new Event(PAYROLL_SCOPE_CHANGE_EVENT, { cancelable: true }));
}
