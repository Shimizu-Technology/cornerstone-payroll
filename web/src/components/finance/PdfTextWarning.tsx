import { AlertTriangle } from 'lucide-react';
import type { InvoicePdfTextIssue } from '@/services/api';

// Characters the invoice PDF can't print. Previews show them as empty boxes
// and issuing is refused until they are replaced.
export function PdfTextWarning({ issues }: { issues?: InvoicePdfTextIssue[] | null }) {
  if (!issues || issues.length === 0) return null;
  return (
    <div role="alert" className="rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
      <p className="flex items-center gap-2 font-semibold">
        <AlertTriangle className="h-4 w-4 shrink-0" aria-hidden="true" />
        Some characters can't print on the invoice PDF
      </p>
      <p className="mt-1">They show as empty boxes in the preview, and the invoice can't be issued until they're replaced with Latin letters.</p>
      <ul className="mt-2 space-y-1">
        {issues.map((issue) => (
          <li key={issue.field}>
            <span className="font-medium">{issue.field}:</span>{' '}
            <span className="font-mono">{issue.characters.join(' ')}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
