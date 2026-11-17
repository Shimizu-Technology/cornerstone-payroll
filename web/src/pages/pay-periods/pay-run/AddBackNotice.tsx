import type { ReactElement } from 'react';

import type { AddBackResult } from '@/types';
import { addBackAmountText, addBackSummary } from './addBackText';

/**
 * Who is back, what the import brought back, and what staff still do. It is
 * not a live region itself; each place that adds someone back announces it
 * through a region that stays mounted.
 */
export function AddBackNotice({ result, hoursEntered = false, noHours = false }: { result: AddBackResult; hoursEntered?: boolean; noHours?: boolean }): ReactElement {
  return <div className="space-y-2 rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-700">
    <p>{addBackSummary(result, hoursEntered, noHours)}</p>
    {!!result.not_restored.length && <div className="text-warning-800">
      <p className="font-medium">Not brought back:</p>
      <ul className="mt-1 list-disc space-y-1 pl-5">
        {result.not_restored.map((entry, index) => <li key={entry.key ?? `${entry.kind}:${index}`} className="break-words">{addBackAmountText(entry)}: {entry.reason}</li>)}
      </ul>
    </div>}
  </div>;
}
