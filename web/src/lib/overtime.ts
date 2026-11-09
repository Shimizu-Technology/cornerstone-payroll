// Overtime premium is an employee protection; 1099 contractors earn their
// contract rate for every hour, including hours a time source marks overtime.
export function overtimeMultiplier(employmentType?: string | null): number {
  return employmentType === 'contractor' ? 1 : 1.5;
}
