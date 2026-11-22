import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { AlertTriangle, ChevronDown, ChevronRight, EyeOff, RefreshCw, StickyNote } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { detectSensitiveNoteContent } from '@/lib/employee-note-validation';
import {
  EMPLOYEE_NOTE_HIDE_REASON_MAX_LENGTH,
  EMPLOYEE_NOTE_MAX_LENGTH,
  employeeNotesApi,
  type EmployeeNote,
  type EmployeeNotesListMeta,
} from '@/services/employee-notes-api';
import { cn, formatGuamDateTime } from '@/lib/utils';

export interface EmployeeNotesPanelProps {
  companyId: number;
  employeeId: number;
  readOnly?: boolean;
  canRevealHidden?: boolean;
  className?: string;
}

export function EmployeeNotesPanel({
  companyId,
  employeeId,
  readOnly = false,
  canRevealHidden = false,
  className,
}: EmployeeNotesPanelProps): ReactElement {
  const noteInputId = useId();
  const helperTextId = useId();
  const scope = `${companyId}:${employeeId}`;
  const scopeRef = useRef(scope);
  const listGenerationRef = useRef(0);
  // True while the newest list request is still in flight.
  const listPendingRef = useRef(false);
  // True once the full list has loaded for the current scope.
  const listLoadedRef = useRef(false);
  // Mirrors the rendered list so a create response can be deduplicated against it.
  const notesRef = useRef<EmployeeNote[]>([]);

  const [notes, setNotes] = useState<EmployeeNote[]>([]);
  const [listMeta, setListMeta] = useState<EmployeeNotesListMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [draftBody, setDraftBody] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const [hidingNoteId, setHidingNoteId] = useState<number | null>(null);
  const [hideReason, setHideReason] = useState('');
  const [hideSubmitting, setHideSubmitting] = useState(false);
  const [hideError, setHideError] = useState<string | null>(null);

  const [expandedHiddenIds, setExpandedHiddenIds] = useState<Record<number, boolean>>({});
  const [revealedBodies, setRevealedBodies] = useState<Record<number, string>>({});
  const [revealingIds, setRevealingIds] = useState<Record<number, boolean>>({});
  const [revealErrors, setRevealErrors] = useState<Record<number, string>>({});

  useLayoutEffect(() => {
    notesRef.current = notes;
  }, [notes]);

  useLayoutEffect(() => {
    scopeRef.current = scope;
    return () => {
      scopeRef.current = '';
    };
  }, [scope]);

  const loadNotes = useCallback(async (): Promise<void> => {
    const requestScope = `${companyId}:${employeeId}`;
    const requestGeneration = ++listGenerationRef.current;
    listPendingRef.current = true;
    setLoading(true);
    setLoadError(null);
    try {
      const response = await employeeNotesApi.list(companyId, employeeId);
      if (scopeRef.current !== requestScope || listGenerationRef.current !== requestGeneration) return;
      setNotes(response.data);
      setListMeta(response.meta ?? null);
      listLoadedRef.current = true;
    } catch (caught) {
      if (scopeRef.current !== requestScope || listGenerationRef.current !== requestGeneration) return;
      setLoadError(caught instanceof Error ? caught.message : 'Could not load staff notes.');
    } finally {
      if (scopeRef.current === requestScope && listGenerationRef.current === requestGeneration) {
        listPendingRef.current = false;
        setLoading(false);
      }
    }
  }, [companyId, employeeId]);

  useEffect(() => {
    listLoadedRef.current = false;
    setNotes([]);
    setListMeta(null);
    setDraftBody('');
    setSubmitError(null);
    setSubmitting(false);
    setHidingNoteId(null);
    setHideReason('');
    setHideError(null);
    setHideSubmitting(false);
    setExpandedHiddenIds({});
    setRevealedBodies({});
    setRevealingIds({});
    setRevealErrors({});
    void loadNotes();
  }, [loadNotes]);

  const sensitiveWarning = useMemo(() => detectSensitiveNoteContent(draftBody), [draftBody]);
  const hideSensitiveWarning = useMemo(
    () => detectSensitiveNoteContent(hideReason, 'This hide reason'),
    [hideReason],
  );

  const handleAddNote = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    if (readOnly || submitting) return;

    const trimmed = draftBody.trim();
    if (!trimmed) {
      setSubmitError('Enter a note before saving.');
      return;
    }

    const requestScope = `${companyId}:${employeeId}`;
    setSubmitting(true);
    setSubmitError(null);
    try {
      const response = await employeeNotesApi.create(companyId, employeeId, trimmed);
      if (scopeRef.current !== requestScope) return;
      // A pending or failed list load was superseded; reload so existing notes aren't lost.
      const reloadList = listPendingRef.current || !listLoadedRef.current;
      listGenerationRef.current += 1;
      listPendingRef.current = false;
      setLoading(false);
      setLoadError(null);
      // The list may already include the new note if it loaded after the create committed.
      if (!notesRef.current.some((item) => item.id === response.data.id)) {
        setNotes((current) => [response.data, ...current]);
        setListMeta((current) => (
          current
            ? {
              ...current,
              returned_count: current.returned_count + 1,
              total_count: current.total_count + 1,
            }
            : current
        ));
      }
      setDraftBody('');
      if (reloadList) void loadNotes();
    } catch (caught) {
      if (scopeRef.current !== requestScope) return;
      setSubmitError(caught instanceof Error ? caught.message : 'Could not save this note.');
    } finally {
      if (scopeRef.current === requestScope) setSubmitting(false);
    }
  };

  const openHideForm = (noteId: number): void => {
    setHidingNoteId(noteId);
    setHideReason('');
    setHideError(null);
  };

  const cancelHideForm = (): void => {
    setHidingNoteId(null);
    setHideReason('');
    setHideError(null);
  };

  const handleConfirmHide = async (noteId: number): Promise<void> => {
    if (readOnly || hideSubmitting) return;

    const trimmedReason = hideReason.trim();
    if (!trimmedReason) {
      setHideError('Enter a reason before hiding this note.');
      return;
    }

    const requestScope = `${companyId}:${employeeId}`;
    setHideSubmitting(true);
    setHideError(null);
    try {
      const response = await employeeNotesApi.hide(companyId, employeeId, noteId, trimmedReason);
      if (scopeRef.current !== requestScope) return;
      const reloadList = listPendingRef.current || !listLoadedRef.current;
      listGenerationRef.current += 1;
      listPendingRef.current = false;
      setLoading(false);
      setLoadError(null);
      setNotes((current) => current.map((item) => (item.id === noteId ? response.data : item)));
      setHidingNoteId(null);
      setHideReason('');
      if (reloadList) void loadNotes();
    } catch (caught) {
      if (scopeRef.current !== requestScope) return;
      setHideError(caught instanceof Error ? caught.message : 'Could not hide this note.');
    } finally {
      if (scopeRef.current === requestScope) setHideSubmitting(false);
    }
  };

  const toggleHiddenNote = async (noteId: number): Promise<void> => {
    if (!canRevealHidden) return;

    if (expandedHiddenIds[noteId]) {
      setExpandedHiddenIds((current) => ({ ...current, [noteId]: false }));
      return;
    }

    if (Object.prototype.hasOwnProperty.call(revealedBodies, noteId)) {
      setExpandedHiddenIds((current) => ({ ...current, [noteId]: true }));
      return;
    }

    if (revealingIds[noteId]) return;

    const requestScope = `${companyId}:${employeeId}`;
    setRevealingIds((current) => ({ ...current, [noteId]: true }));
    setRevealErrors((current) => {
      const next = { ...current };
      delete next[noteId];
      return next;
    });

    try {
      const response = await employeeNotesApi.original(companyId, employeeId, noteId);
      if (scopeRef.current !== requestScope) return;
      setRevealedBodies((current) => ({ ...current, [noteId]: response.data.body ?? '' }));
      setExpandedHiddenIds((current) => ({ ...current, [noteId]: true }));
    } catch (caught) {
      if (scopeRef.current !== requestScope) return;
      setRevealErrors((current) => ({
        ...current,
        [noteId]: caught instanceof Error ? caught.message : 'Could not load the original note.',
      }));
    } finally {
      if (scopeRef.current === requestScope) {
        setRevealingIds((current) => ({ ...current, [noteId]: false }));
      }
    }
  };

  const remaining = EMPLOYEE_NOTE_MAX_LENGTH - draftBody.length;
  const nearLimit = remaining <= 150;

  return (
    <Card id="employee-notes" className={cn('scroll-mt-28', className)}>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <span
            aria-hidden="true"
            className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700 ring-1 ring-primary-100"
          >
            <StickyNote className="h-5 w-5" />
          </span>
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <CardTitle>Notes</CardTitle>
              <Badge variant="default">Staff only</Badge>
            </div>
            <CardDescription className="mt-1">
              Append-only payroll context for Cornerstone staff. Not visible to clients or employees.
            </CardDescription>
          </div>
        </div>
      </CardHeader>

      <CardContent className="space-y-5">
        {!readOnly && (
          <form onSubmit={(event) => void handleAddNote(event)} className="space-y-3" noValidate>
            <div className="space-y-2">
              <label htmlFor={noteInputId} className="block text-sm font-medium text-neutral-800">
                Add a staff note
              </label>
              <Textarea
                id={noteInputId}
                value={draftBody}
                maxLength={EMPLOYEE_NOTE_MAX_LENGTH}
                rows={3}
                disabled={submitting}
                aria-describedby={helperTextId}
                aria-invalid={submitError ? true : undefined}
                placeholder="Example: Roke said her start date was Nov 15; the W-4 says Nov 16."
                onChange={(event) => {
                  setDraftBody(event.target.value);
                  if (submitError) setSubmitError(null);
                }}
              />
              <div
                id={helperTextId}
                className="flex flex-col gap-1 text-xs leading-5 text-neutral-600 sm:flex-row sm:items-center sm:justify-between"
              >
                <span>Don&apos;t enter SSNs, bank or card numbers.</span>
                <span className={cn('tabular-nums font-medium', nearLimit ? 'text-warning-800' : 'text-neutral-500')}>
                  {draftBody.length.toLocaleString()} / {EMPLOYEE_NOTE_MAX_LENGTH.toLocaleString()}
                </span>
              </div>
            </div>

            {sensitiveWarning && (
              <div
                role="status"
                className="flex items-start gap-2 rounded-xl border border-warning-200 bg-warning-50 px-3.5 py-2.5 text-sm leading-5 text-warning-900"
              >
                <AlertTriangle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" />
                <span>{sensitiveWarning.message}</span>
              </div>
            )}

            {submitError && (
              <p
                role="alert"
                className="rounded-xl border border-danger-200 bg-danger-50 px-3.5 py-2.5 text-sm leading-5 text-danger-800"
              >
                {submitError}
              </p>
            )}

            <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
              <p className="text-xs leading-5 text-neutral-500">
                Notes cannot be edited once saved. To correct a note, add a new one.
              </p>
              <Button type="submit" disabled={submitting} className="min-h-11 w-full sm:w-auto">
                {submitting ? 'Saving note…' : 'Add note'}
              </Button>
            </div>
          </form>
        )}

        <div className="border-t border-neutral-200 pt-4">
          {loading ? (
            <div role="status" aria-live="polite" className="space-y-3">
              <p className="text-sm text-neutral-500">Loading notes…</p>
              <div className="h-16 animate-pulse rounded-xl bg-neutral-100" />
              <div className="h-16 animate-pulse rounded-xl bg-neutral-100" />
            </div>
          ) : loadError ? (
            <div
              role="alert"
              className="flex flex-col gap-3 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-900 sm:flex-row sm:items-center sm:justify-between"
            >
              <p className="min-w-0 break-words leading-6">{loadError}</p>
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="min-h-11 w-full shrink-0 sm:w-auto"
                onClick={() => void loadNotes()}
              >
                <RefreshCw className="mr-2 h-4 w-4" />
                Try again
              </Button>
            </div>
          ) : notes.length === 0 ? (
            <div className="rounded-xl border border-dashed border-neutral-200 bg-neutral-50/70 px-4 py-6 text-center">
              <p className="text-sm font-medium text-neutral-800">No staff notes yet</p>
              <p className="mt-1 text-xs leading-5 text-neutral-500">
                Record discrepancies, verification calls, or payroll context for this employee.
              </p>
            </div>
          ) : (
            <div className="space-y-3">
              {listMeta?.truncated && (
                <p className="text-xs text-neutral-500">
                  Showing the newest {listMeta.returned_count.toLocaleString()} of {listMeta.total_count.toLocaleString()} notes.
                </p>
              )}
              <ol className="space-y-3" aria-label="Staff notes">
                {notes.map((note) => {
                  if (note.hidden) {
                    const isExpanded = Boolean(expandedHiddenIds[note.id]);
                    const isRevealing = Boolean(revealingIds[note.id]);
                    const revealError = revealErrors[note.id];
                    const revealedBody = revealedBodies[note.id];
                    const hiddenByLabel = note.hidden_by_name || 'Staff';
                    return (
                      <li
                        key={note.id}
                        className="rounded-xl border border-neutral-200 bg-neutral-50/90 px-4 py-3 text-sm text-neutral-600"
                      >
                        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                          <div className="min-w-0 space-y-1">
                            <p className="break-words font-medium text-neutral-700">
                              <span className="inline-flex items-center gap-1.5">
                                <EyeOff aria-hidden="true" className="h-3.5 w-3.5 shrink-0 text-neutral-500" />
                                <span>
                                  Hidden by {hiddenByLabel}: {note.hidden_reason}
                                </span>
                              </span>
                            </p>
                            <p className="text-xs text-neutral-500">
                              Hidden {formatGuamDateTime(note.hidden_at)}
                            </p>
                          </div>
                          {canRevealHidden && (
                            <button
                              type="button"
                              aria-expanded={isExpanded}
                              disabled={isRevealing}
                              onClick={() => void toggleHiddenNote(note.id)}
                              className="inline-flex min-h-11 items-center gap-1 self-start rounded-lg px-2 text-xs font-semibold text-neutral-600 hover:bg-neutral-200/70 hover:text-neutral-900 disabled:opacity-60 sm:self-center"
                            >
                              {isExpanded ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
                              {isRevealing ? 'Loading…' : isExpanded ? 'Collapse' : 'Show original'}
                            </button>
                          )}
                        </div>
                        {revealError && (
                          <p
                            role="alert"
                            className="mt-2 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-xs font-medium text-danger-800"
                          >
                            {revealError}
                          </p>
                        )}
                        {canRevealHidden && isExpanded && revealedBody !== undefined && (
                          <div className="mt-3 border-t border-neutral-200 pt-3">
                            <p className="text-xs font-medium text-neutral-500">
                              Originally added by {note.created_by_name} · {formatGuamDateTime(note.created_at)}
                            </p>
                            <p className="mt-1.5 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-700">
                              {revealedBody}
                            </p>
                          </div>
                        )}
                      </li>
                    );
                  }

                  const isHiding = hidingNoteId === note.id;
                  return (
                    <li
                      key={note.id}
                      className="rounded-xl border border-neutral-200 bg-white px-4 py-3.5 shadow-xs"
                    >
                      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <p className="text-xs font-semibold text-neutral-700">
                            {note.created_by_name}
                            <span className="font-normal text-neutral-500"> · {formatGuamDateTime(note.created_at)}</span>
                          </p>
                        </div>
                        {!readOnly && !isHiding && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="min-h-11 self-start px-2.5 text-xs font-semibold text-neutral-600 hover:text-neutral-900 sm:min-h-9"
                            onClick={() => openHideForm(note.id)}
                          >
                            <EyeOff className="mr-1.5 h-3.5 w-3.5" />
                            Hide
                          </Button>
                        )}
                      </div>

                      <p className="mt-2 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-900">
                        {note.body}
                      </p>

                      {isHiding && (
                        <div className="mt-3 space-y-3 rounded-xl border border-neutral-200 bg-neutral-50 p-3.5">
                          <Input
                            id={`hide-note-reason-${note.id}`}
                            label="Reason for hiding"
                            value={hideReason}
                            maxLength={EMPLOYEE_NOTE_HIDE_REASON_MAX_LENGTH}
                            disabled={hideSubmitting}
                            placeholder="Explain why this note is being hidden"
                            onChange={(event) => {
                              setHideReason(event.target.value);
                              if (hideError) setHideError(null);
                            }}
                          />
                          {hideSensitiveWarning && (
                            <div
                              role="status"
                              className="flex items-start gap-2 rounded-xl border border-warning-200 bg-warning-50 px-3 py-2 text-xs leading-5 text-warning-900"
                            >
                              <AlertTriangle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" />
                              <span>{hideSensitiveWarning.message}</span>
                            </div>
                          )}
                          {hideError && (
                            <p role="alert" className="text-xs font-medium text-danger-700">
                              {hideError}
                            </p>
                          )}
                          <div className="flex flex-col gap-2 sm:flex-row sm:justify-end">
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              className="min-h-11 w-full sm:w-auto"
                              disabled={hideSubmitting}
                              onClick={cancelHideForm}
                            >
                              Cancel
                            </Button>
                            <Button
                              type="button"
                              variant="danger"
                              size="sm"
                              className="min-h-11 w-full sm:w-auto"
                              disabled={hideSubmitting}
                              onClick={() => void handleConfirmHide(note.id)}
                            >
                              {hideSubmitting ? 'Hiding…' : 'Hide note'}
                            </Button>
                          </div>
                        </div>
                      )}
                    </li>
                  );
                })}
              </ol>
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
