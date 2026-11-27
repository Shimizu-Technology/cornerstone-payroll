import { useState } from 'react';
import { CheckCircle2, CircleDashed, Upload, X } from 'lucide-react';
import type { ImportPackageSource } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { MOSA_SOURCE_ACCEPT } from '@/lib/importSources';
import { cn } from '@/lib/utils';

interface Props {
  sources: ImportPackageSource[];
  summary: string;
  acceptByRole?: Record<string, string>;
  // Omitted when files must be added another way (a client portal revision).
  onAdd?: (role: string, file: File) => void;
  // Omitted when a file cannot be taken out (an applied import, a portal revision, or its only file).
  onRemove?: (role: string, reason: string) => Promise<boolean>;
  busy?: boolean;
  waived: boolean;
  onWaivedChange: (waived: boolean) => void;
  // The client already said there is nothing to send for these files.
  clientWaived?: boolean;
  // Set when the client sent the file or a link to it, so staff cannot record "none".
  waiverBlockedReason?: string | null;
}

// Which files this import has, which are still needed, and a way to add the
// missing one or take out one added by mistake without starting over.
export function ImportSourceChecklist({ sources, summary, acceptByRole, onAdd, onRemove, busy, waived, onWaivedChange, clientWaived, waiverBlockedReason }: Props) {
  const [removing, setRemoving] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [removeBusy, setRemoveBusy] = useState(false);
  const waivable = sources.filter((source) => source.required && !source.present && source.waiver_label);
  const removingSource = sources.find((source) => source.role === removing);

  const confirmRemove = async () => {
    if (!onRemove || !removing || !reason.trim()) return;
    setRemoveBusy(true);
    const removed = await onRemove(removing, reason.trim());
    setRemoveBusy(false);
    if (removed) { setRemoving(null); setReason(''); }
  };

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
            {source.present && onRemove && removing !== source.role && (
              <button
                type="button"
                className="inline-flex min-h-11 items-center gap-1 rounded-lg px-2 text-sm font-medium text-neutral-700 underline-offset-2 hover:text-danger-700 hover:underline disabled:opacity-60"
                aria-label={`Remove ${source.label}`}
                disabled={busy || removeBusy}
                onClick={() => { setRemoving(source.role); setReason(''); }}
              >
                <X className="h-4 w-4" aria-hidden="true" />
                Remove
              </button>
            )}
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
                  accept={source.accept?.join(',') || acceptByRole?.[source.role] || MOSA_SOURCE_ACCEPT[source.role]}
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
      {removingSource && onRemove && (
        <form
          className="mt-3 space-y-2 rounded-xl border border-neutral-300 bg-neutral-50 p-3"
          onSubmit={(event) => { event.preventDefault(); void confirmRemove(); }}
        >
          <p className="font-medium text-neutral-950">Remove the {removingSource.label} from this import?</p>
          <p className="text-neutral-700">The other files are kept and matched again as a new import version. Outcomes you chose stay.</p>
          <Input
            label="Why remove it?"
            value={reason}
            maxLength={500}
            autoFocus
            onChange={(event) => setReason(event.target.value)}
            placeholder="Example: Added last period’s workbook by mistake."
            className="bg-white"
          />
          <div className="flex flex-col gap-2 sm:flex-row">
            <Button type="submit" variant="outline" className="border-danger-300 text-danger-800" disabled={!reason.trim() || removeBusy}>
              {removeBusy ? 'Removing…' : `Remove ${removingSource.label}`}
            </Button>
            <Button type="button" variant="ghost" disabled={removeBusy} onClick={() => { setRemoving(null); setReason(''); }}>Keep it</Button>
          </div>
        </form>
      )}
      {waivable.length > 0 && (clientWaived
        ? <p className="mt-2 text-sm text-neutral-700">The client chose: {waivable.map((source) => source.waiver_label).join(' · ')}.</p>
        : waiverBlockedReason ? <p className="mt-2 text-sm font-medium text-amber-900">{waiverBlockedReason}</p> : (
          <label className="mt-2 flex min-h-11 items-center gap-2 font-medium text-neutral-900">
            <input type="checkbox" className="h-4 w-4 shrink-0" checked={waived} onChange={(event) => onWaivedChange(event.target.checked)} />
            {waivable.map((source) => source.waiver_label).join(' · ')}
          </label>
        ))}
      <p className="mt-1 text-xs text-neutral-600">{summary}</p>
    </section>
  );
}
