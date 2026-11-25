import type { ReactElement } from 'react';
import { Eye } from 'lucide-react';

export interface ViewOnlyGrant {
  /** The person being viewed, e.g. "Emma Pleadwell". */
  name: string;
  minutesLeft?: number | null;
  onEnd: () => void;
  ending?: boolean;
  error?: string | null;
}

/**
 * Shown the whole time a Cornerstone admin uses the view-only "Sign in as"
 * (M4-9). It sits above the header and takes the top safe area.
 */
export function ViewOnlyBanner({ name, minutesLeft, onEnd, ending, error }: ViewOnlyGrant): ReactElement {
  const remaining = typeof minutesLeft === 'number' && minutesLeft >= 0
    ? ` · ${minutesLeft} min left` : '';
  return (
    <section className="emp-viewas" aria-label="View only">
      <span aria-hidden="true" className="grid size-9 shrink-0 place-items-center rounded-[10px] bg-warning-300 text-neutral-900">
        <Eye className="size-5" />
      </span>
      <p className="min-w-0 flex-1">
        <strong className="block break-words text-[0.98rem] leading-snug">Viewing as {name}, view only</strong>
        {remaining && <span className="text-[0.85rem] font-semibold text-warning-300">{remaining}</span>}
        {error && <span className="block text-sm" role="alert">{error}</span>}
      </p>
      <button type="button" className="emp-btn emp-viewas-end" onClick={onEnd} disabled={ending}>{ending ? 'Ending…' : 'End'}</button>
    </section>
  );
}
