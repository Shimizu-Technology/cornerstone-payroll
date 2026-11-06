import { Link } from 'react-router';
import type { FilingEmployeeCompleteness } from '@/types';

export function FilingEmployeeWarnings({ completeness, compact = false }: { completeness?: FilingEmployeeCompleteness | null; compact?: boolean }) {
  if (!completeness?.employees.length) return null;

  const employeeList = (
    <ul className="mt-3 max-h-60 space-y-2 overflow-y-auto text-sm">
      {completeness.employees.map((employee) => (
        <li key={employee.employee_id} className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span className="break-words">{employee.name} — missing {employee.missing_fields.map((field) => field === 'ssn' ? '9-digit SSN' : 'complete address').join(' and ')}</span>
          <Link to={employee.edit_path} target="_blank" rel="noopener noreferrer" className="font-semibold underline underline-offset-2">Edit profile <span className="sr-only">for {employee.name} (opens in a new tab)</span></Link>
        </li>
      ))}
    </ul>
  );

  return (
    <section aria-label="Missing employee filing details" className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-warning-900">
      <h3 className="font-semibold">Complete employee details before filing</h3>
      <p className="mt-1 text-sm leading-6">{compact
        ? `${completeness.missing_ssn_count} missing SSN; ${completeness.missing_address_count} incomplete address. Missing details print blank. Add them before filing; drafts remain available.`
        : completeness.message}</p>
      {compact ? (
        <details className="mt-2 text-sm">
          <summary className="cursor-pointer font-semibold">Review affected employees ({completeness.employees.length})</summary>
          {employeeList}
        </details>
      ) : employeeList}
    </section>
  );
}
