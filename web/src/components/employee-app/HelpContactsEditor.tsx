import { useId, type ReactElement } from 'react';
import { ArrowDown, ArrowUp, Plus, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { draftProblems, toDraft, type HelpContactDraft } from '@/lib/help-contact-drafts';

interface Props {
  drafts: HelpContactDraft[];
  max: number;
  disabled: boolean;
  showProblems: boolean;
  serverErrors: Record<number, string[]>;
  onChange: (drafts: HelpContactDraft[]) => void;
}

/** Up to five people employees can ask, in the order employees see them. */
export function HelpContactsEditor({ drafts, max, disabled, showProblems, serverErrors, onChange }: Props): ReactElement {
  const listId = useId();
  const update = (index: number, patch: Partial<HelpContactDraft>): void => {
    onChange(drafts.map((draft, i) => (i === index ? { ...draft, ...patch } : draft)));
  };
  const move = (index: number, offset: number): void => {
    const next = [...drafts];
    const [moved] = next.splice(index, 1);
    next.splice(index + offset, 0, moved);
    onChange(next);
  };

  return (
    <div className="space-y-4">
      {drafts.length > 0 && (
        <ol id={listId} className="space-y-4" aria-label="Help contacts, in the order employees see them">
          {drafts.map((draft, index) => {
            const problems = showProblems ? draftProblems(draft) : {};
            const errors = serverErrors[index] ?? [];
            const label = draft.name.trim() || `Contact ${index + 1}`;
            return (
              <li key={draft.key} className="rounded-2xl border border-neutral-200 bg-white p-4">
                <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <p className="text-sm font-semibold text-neutral-900">
                    <span className="mr-2 inline-grid size-6 place-items-center rounded-full bg-neutral-100 text-xs text-neutral-700">{index + 1}</span>
                    {index === 0 ? 'Shown first' : `Shown ${ordinal(index + 1)}`}
                  </p>
                  <div className="flex gap-1">
                    <Button type="button" variant="ghost" size="md" className="px-3" disabled={disabled || index === 0} onClick={() => move(index, -1)} aria-label={`Move ${label} up`}>
                      <ArrowUp aria-hidden="true" className="size-4" />
                    </Button>
                    <Button type="button" variant="ghost" size="md" className="px-3" disabled={disabled || index === drafts.length - 1} onClick={() => move(index, 1)} aria-label={`Move ${label} down`}>
                      <ArrowDown aria-hidden="true" className="size-4" />
                    </Button>
                    <Button type="button" variant="ghost" size="md" className="px-3" disabled={disabled} onClick={() => onChange(drafts.filter((_, i) => i !== index))} aria-label={`Remove ${label}`}>
                      <Trash2 aria-hidden="true" className="size-4" />
                      <span className="ml-1">Remove</span>
                    </Button>
                  </div>
                </div>
                <div className="grid gap-3 sm:grid-cols-2">
                  <Input label="Name" value={draft.name} maxLength={80} autoComplete="off" disabled={disabled}
                    error={problems.name} onChange={(event) => update(index, { name: event.target.value })} />
                  <Input label="Role (optional)" placeholder="General manager" value={draft.role} maxLength={60} autoComplete="off" disabled={disabled}
                    onChange={(event) => update(index, { role: event.target.value })} />
                  <Input label="Phone" type="tel" inputMode="tel" value={draft.phone} maxLength={30} autoComplete="off" disabled={disabled}
                    error={problems.phone} onChange={(event) => update(index, { phone: event.target.value, text_ok: event.target.value.trim() ? draft.text_ok : false })} />
                  <Input label="Email" type="email" inputMode="email" value={draft.email} maxLength={254} autoComplete="off" disabled={disabled}
                    error={problems.email} onChange={(event) => update(index, { email: event.target.value })} />
                </div>
                <label className="mt-3 flex min-h-11 items-center gap-3 text-sm text-neutral-800">
                  <input
                    type="checkbox"
                    className="size-5 rounded border-neutral-300"
                    checked={draft.text_ok}
                    disabled={disabled || !draft.phone.trim()}
                    onChange={(event) => update(index, { text_ok: event.target.checked })}
                  />
                  <span>
                    Employees can text this number
                    {!draft.phone.trim() && <span className="block text-xs text-neutral-500">Add a phone number first.</span>}
                  </span>
                </label>
                {(problems.reach || errors.length > 0) && (
                  <div role="alert" className="mt-2 space-y-1 text-sm text-danger-700">
                    {problems.reach && <p>{problems.reach}</p>}
                    {errors.map((message) => <p key={message}>{message}</p>)}
                  </div>
                )}
              </li>
            );
          })}
        </ol>
      )}
      {drafts.length < max ? (
        <Button type="button" variant="secondary" disabled={disabled} onClick={() => onChange([...drafts, toDraft()])}>
          <Plus aria-hidden="true" className="mr-1 size-4" />
          {drafts.length === 0 ? 'Add a Help contact' : 'Add another contact'}
        </Button>
      ) : (
        <p className="text-sm text-neutral-600">You've added the most contacts employees can see ({max}). Remove one to add someone else.</p>
      )}
    </div>
  );
}

function ordinal(n: number): string {
  return ['first', 'second', 'third', 'fourth', 'fifth'][n - 1] ?? `${n}th`;
}
