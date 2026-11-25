import { Link } from 'react-router';
import { FileText } from 'lucide-react';
import { Alert } from '@/components/ui/alert';
import { employeeDocumentsPath } from '@/lib/routes';
import type { NewHireDocumentGap } from '@/types';

/** Each new hire with the documents still needed, linked to their document manager. */
export function NewHireDocumentLinks({ gaps, companyId, returnTo }: { gaps: NewHireDocumentGap[]; companyId: number; returnTo: string }) {
  return <ul className="mt-2 space-y-2">
    {gaps.map(gap => <li key={gap.employee_id} className="flex flex-col gap-1 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-3">
      <span className="min-w-0 break-words"><span className="font-semibold">{gap.employee_name}</span>: {gap.missing.join(', ')}</span>
      <Link aria-label={`Upload or verify documents for ${gap.employee_name}`} className="inline-flex min-h-11 items-center gap-1 font-semibold text-primary-800 underline sm:min-h-0" to={employeeDocumentsPath(companyId, gap.employee_id, { returnTo })}>
        <FileText className="h-4 w-4 shrink-0" aria-hidden="true" />Upload or verify documents
      </Link>
    </li>)}
  </ul>;
}

export function NewHireDocumentsNotice({ gaps, companyId, returnTo, status }: { gaps: NewHireDocumentGap[] | undefined; companyId: number; returnTo: string; status: string }) {
  if (!gaps?.length) return null;
  const step = status === 'approved' ? 'committing' : 'approving';
  return <Alert id="payroll-new-hire-documents" tabIndex={-1}>
    <h2 className="font-semibold">New-hire documents needed before {step}</h2>
    <p className="mt-1">Upload and verify each new hire's documents, or record a waiver. You can enter hours and calculate in the meantime.</p>
    <NewHireDocumentLinks gaps={gaps} companyId={companyId} returnTo={returnTo} />
  </Alert>;
}
