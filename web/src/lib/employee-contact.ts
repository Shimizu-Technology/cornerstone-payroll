import { CONTACT_EMPLOYEE_FIELDS, type ContactEmployee, type Employee } from '@/types';

// Contact screens keep only contact fields. The web guide says never to keep
// a full SSN (or other payroll data) in frontend state, so anything else a
// response carries is dropped before it's stored.
export function toContactRecord(employee: Employee | ContactEmployee): ContactEmployee {
  const record: Partial<Record<keyof ContactEmployee, unknown>> = {};
  for (const field of CONTACT_EMPLOYEE_FIELDS) {
    if (field in employee) record[field] = employee[field];
  }
  return record as ContactEmployee;
}

// "+1 671 555-0142" for North American numbers; anything else as saved.
export function formatPhone(value: string | null | undefined): string {
  const phone = (value ?? '').trim();
  const match = phone.match(/^\+1(\d{3})(\d{3})(\d{4})$/);
  return match ? `+1 ${match[1]} ${match[2]}-${match[3]}` : phone;
}
