import type { Employee } from '@/types';

export const intakeFieldLabels: Record<string, string> = {
  ssn: 'Social Security Number', contractor_ein: 'Contractor EIN', hire_date: 'Hire date',
  address_line1: 'Street address', city: 'City', state: 'State', zip: 'ZIP code',
  withholding_election: 'Employee withholding election',
};

export function intakeAllowsBlank(employee: Employee | null, field: string, entryEnabled: boolean): boolean {
  if (!employee) return entryEnabled && Object.hasOwn(intakeFieldLabels, field);
  return Boolean(employee.intake_readiness?.exception && employee.intake_readiness.missing_fields.includes(field));
}
