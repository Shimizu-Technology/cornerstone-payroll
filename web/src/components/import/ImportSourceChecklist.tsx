import { CheckCircle2, CircleDashed, Upload } from 'lucide-react';
import type { ImportPackageSource } from '@/services/api';
import { MOSA_SOURCE_ACCEPT } from '@/lib/importSources';
import { cn } from '@/lib/utils';

interface Props {
  sources: ImportPackageSource[];
  summary: string;
  // Omitted when files must be added another way (a client portal revision).
  onAdd?: (role: string, file: File) => void;
  busy?: boolean;
  waived: boolean;
  onWaivedChange: (waived: boolean) => void;
  // The client already said there is nothing to send for these files.
  clientWaived?: boolean;
}

// Which files this import has, which are still needed, and a way to add the
// missing one without starting over.
export function ImportSourceChecklist({ sources, summary, onAdd, busy, waived, onWaivedChange, clientWaived }: Props) {
  const waivable = sources.filter((source) => source.required && !source.present && source.waiver_label);
  return (
    <section aria-label="Files for this import" data-attention="sources" tabIndex={-1} className="rounded-2xl border border-neutral-200 bg-white p-3 text-sm sm:p-4">
      <ul className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:gap-x-6">
        {sources.map((source) => (
          <li key={source.role} className="flex min-h-11 min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
            {source.present
              ? <CheckCircle2 className="h-5 w-5 shrink-0 text-green-700" aria-hidden="true" />
              : <CircleDashed className={cn('h-5 w-5 shrink-0', source.required && !waived && !clientWaived ? 'text-amber-700' : 'text-neutral-400')} aria-hidden="true" />}
            <span className="font-medium text-neutral-950">{source.label}</span>
            <span className="sr-only">{source.present ? 'added' : source.required ? 'missing' : 'not added, optional'}</span>
            {source.present && source.filename && <span className="min-w-0 break-all text-xs text-neutral-600">{source.filename}</span>}
            {!source.present && !source.required && <span className="text-xs text-neutral-600">Optional</span>}
            {!source.present && onAdd && (
              <label className={cn(
                'inline-flex min-h-11 cursor-pointer items-center gap-1.5 rounded-lg border border-primary-300 bg-primary-50 px-3 font-semibold text-primary-800 focus-within:ring-2 focus-within:ring-primary-500 hover:bg-primary-100',
                busy && 'pointer-events-none opacity-60',
              )}>
                <Upload className="h-4 w-4" aria-hidden="true" />
                {busy ? 'Adding…' : 'Add'}
                <input
                  type="file"
                  className="sr-only"
                  aria-label={`Add ${source.label}`}
                  accept={MOSA_SOURCE_ACCEPT[source.role]}
                  disabled={busy}
                  onChange={(event) => {
                    const file = event.target.files?.[0];
                    event.target.value = '';
                    if (file) onAdd(source.role, file);
                  }}
                />
              </label>
            )}
          </li>
        ))}
      </ul>
      {waivable.length > 0 && (clientWaived
        ? <p className="mt-2 text-sm text-neutral-700">The client chose: {waivable.map((source) => source.waiver_label).join(' · ')}.</p>
        : (
          <label className="mt-2 flex min-h-11 items-center gap-2 font-medium text-neutral-900">
            <input type="checkbox" className="h-4 w-4 shrink-0" checked={waived} onChange={(event) => onWaivedChange(event.target.checked)} />
            {waivable.map((source) => source.waiver_label).join(' · ')}
          </label>
        ))}
      <p className="mt-1 text-xs text-neutral-600">{summary}</p>
    </section>
  );
}
