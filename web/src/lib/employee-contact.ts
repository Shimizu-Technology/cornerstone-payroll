import type { Employee } from '@/types';

// Contact screens only need contact fields. The web guide says never to keep
// a full SSN in frontend state, so drop it from any record they store.
export function withoutFullSsn(employee: Employee): Employee {
  const contactOnly = { ...employee };
  delete contactOnly.ssn;
  return contactOnly;
}
