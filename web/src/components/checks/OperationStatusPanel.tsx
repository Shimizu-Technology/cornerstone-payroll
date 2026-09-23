import { CheckCircle2, CircleAlert, LoaderCircle } from 'lucide-react';
import type { CheckPrintGeneration } from '@/types';

const PHASE_COPY: Record<CheckPrintGeneration['phase'], string> = {
  queued: 'Waiting for a generation worker…',
  validating: 'Validating the selected checks and printer profile…',
  rendering: 'Rendering each check from the saved selection…',
  assembling: 'Assembling the checks into one package…',
  uploading: 'Saving the immutable PDF package…',
  verifying: 'Verifying the saved file before it becomes printable…',
  ready: 'Package generated and verified.',
  failed: 'Package generation stopped.',
};

interface OperationStatusPanelProps {
  generation: CheckPrintGeneration;
  showLongRunningHint: boolean;
  onRetry: () => void;
  retryDisabled?: boolean;
}

export function OperationStatusPanel({ generation, showLongRunningHint, onRetry, retryDisabled = false }: OperationStatusPanelProps) {
  const failed = generation.status === 'failed';
  const ready = generation.status === 'ready';
  const progress = generation.total_items > 0
    ? Math.round((generation.completed_items / generation.total_items) * 100)
    : 0;

  return (
    <section
      aria-live="polite"
      aria-atomic="true"
      className={`rounded-2xl border p-4 ${failed ? 'border-red-200 bg-red-50' : ready ? 'border-emerald-200 bg-emerald-50' : 'border-blue-200 bg-blue-50'}`}
    >
      <div className="flex items-start gap-3">
        {failed ? (
          <CircleAlert aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-red-700" />
        ) : ready ? (
          <CheckCircle2 aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" />
        ) : (
          <LoaderCircle aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 animate-spin text-blue-700 motion-reduce:animate-none" />
        )}
        <div className="min-w-0 flex-1">
          <p className={`text-sm font-semibold ${failed ? 'text-red-950' : ready ? 'text-emerald-950' : 'text-blue-950'}`}>
            {failed ? 'Package not generated' : ready ? 'Package ready' : 'Generating and saving package'}
          </p>
          <p className={`mt-1 text-xs leading-5 ${failed ? 'text-red-800' : ready ? 'text-emerald-800' : 'text-blue-800'}`}>
            {generation.error_message || PHASE_COPY[generation.phase]}
          </p>
          {!failed && !ready && (
            <>
              <div className="mt-3 h-2 overflow-hidden rounded-full bg-blue-100" role="progressbar" aria-label="Package generation progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={generation.phase === 'rendering' ? progress : undefined}>
                <div
                  className={`${generation.phase === 'rendering' ? '' : 'animate-pulse motion-reduce:animate-none'} h-full rounded-full bg-blue-700 transition-[width] duration-300`}
                  style={{ width: generation.phase === 'rendering' ? `${Math.max(4, progress)}%` : '45%' }}
                />
              </div>
              <div className="mt-2 flex items-center justify-between gap-3 text-xs text-blue-800">
                <span className="capitalize">{generation.phase}</span>
                <span>{generation.phase === 'rendering' ? `${generation.completed_items} of ${generation.total_items} checks` : `${generation.total_items} checks selected`}</span>
              </div>
              {showLongRunningHint && (
                <p className="mt-3 border-t border-blue-200 pt-3 text-xs leading-5 text-blue-900">
                  Larger packages can take a little longer. You can close this window; generation will continue and reconnect when you return.
                </p>
              )}
            </>
          )}
          {failed && (
            <>
              <button type="button" onClick={onRetry} disabled={retryDisabled} className="mt-3 text-xs font-semibold text-red-800 underline underline-offset-2 disabled:cursor-not-allowed disabled:text-red-400 disabled:no-underline">
                Try again with the same selection
              </button>
              {retryDisabled && <p className="mt-2 text-xs leading-5 text-red-800">Save or discard check-number changes before retrying.</p>}
            </>
          )}
        </div>
      </div>
    </section>
  );
}
