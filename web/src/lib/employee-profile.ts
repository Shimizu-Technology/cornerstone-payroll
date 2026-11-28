import type { Employee } from '@/types';

export const canonicalSsn = (value?: string) => (value || '').replace(/\D/g, '');

// Mask SSNs and formatted EINs in free text, preserving standalone long references.
export function maskTaxIdsInText(value: string, mask: '•' | '*' = '•'): string {
  return value
    .replace(/\b\d{3}[-\s]?\d{2}[-\s]?(\d{4})\b/g, `${mask.repeat(3)}-${mask.repeat(2)}-$1`)
    .replace(/\b\d{2}-\d{3}(\d{4})\b/g, `${mask.repeat(2)}-${mask.repeat(3)}$1`);
}

// Match the API's source-review exception. An unrelated edit must not clear it.
export function importedProfileAllowsBlank(employee: Employee | null, field: string): boolean {
  return employee?.configuration_source === 'quickbooks_history'
    && employee.configuration_review_status === 'needs_review'
    && Boolean(employee.configuration_review_items?.some((item) =>
      ['verify_hire_date', 'quickbooks_nevada_address_suppressed', 'employee_address_missing'].includes(item.code)
      && item.fields.includes(field)));
}

export function validateHireDate(value: string): string | null {
  if (!value) return null;
  const year = Number(value.slice(0, 4));
  return year < 1900 || year > new Date().getFullYear() + 1 || !/^\d{4}-\d{2}-\d{2}$/.test(value)
    ? 'Hire date must have a year between 1900 and next year' : null;
}

export function withDocumentReadiness(
  employee: Employee | null,
  expectedEmployeeId: number,
  readiness: Employee['document_readiness'],
): Employee | null {
  return employee?.id === expectedEmployeeId ? { ...employee, document_readiness: readiness } : employee;
}
