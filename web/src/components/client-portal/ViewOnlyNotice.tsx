import { Eye } from 'lucide-react';
import { CLIENT_VIEW_ONLY_MESSAGE } from '@/lib/company-write-access';

/** Shown where a Client viewer would otherwise see a button that changes something. */
export function ViewOnlyNotice({ className = '' }: { className?: string }) {
  return (
    <p role="note" className={`flex items-start gap-2 text-sm text-neutral-700 ${className}`}>
      <Eye className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" aria-hidden="true" />
      <span>{CLIENT_VIEW_ONLY_MESSAGE}</span>
    </p>
  );
}
