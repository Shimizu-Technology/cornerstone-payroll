import { useEffect, useRef, useState, type KeyboardEvent, type ReactElement } from 'react';
import { AlertTriangle, Pencil } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ViewOnlyNotice } from '@/components/client-portal/ViewOnlyNotice';
import { formatPhone } from '@/lib/display-phone';
import { toContactRecord } from '@/lib/employee-contact';
import { clientEmployeesApi, employeesApi } from '@/services/api';
import type { ContactEmployee, Employee } from '@/types';
import {
  AddressValue,
  ContactEditor,
  ContactSaveResult,
  ContactValue,
  SharedEmailNote,
} from './ContactEditor';
import {
  INITIAL_ROW_STATE,
  contactStatusBadge,
  editRowDraft,
  effectiveDraft,
  extractConflictPayload,
  extractContactValidation,
  hasAnyChangedField,
  keepMineRow,
  rowSaveRequest,
  theirsWinRow,
  type ContactField,
  type RowFieldDrafts,
  type RowSaveState,
} from '@/lib/employee-contact-editor';

export interface EmployeeContactCardProps {
  employee: Employee | ContactEmployee;
  companyId: number;
  audience: 'admin' | 'client';
  /** False for a Client viewer or a read-only workspace: the card only shows. */
  canEdit: boolean;
  /** A Client viewer sees why there's no Edit button. */
  viewOnly?: boolean;
  /** Each increment opens the editor, for links elsewhere on the page. */
  editRequest?: number;
  /**
   * The server's copy changed: after a save, or when a conflict showed
   * someone else's newer record. emailChanged compares with the page's copy.
   */
  onRecordChange?: (record: ContactEmployee, change: { emailChanged: boolean; savedFields: ContactField[] }) => void;
}

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

// Email, mobile and mailing address on the employee page. Saves go through
// the same employee update endpoint as the Contact details grid, with each
// edited field's saved value and row revision from when it was first edited,
// so a coworker's change in the meantime comes back as a conflict to resolve
// instead of being overwritten.
export function EmployeeContactCard({
  employee, companyId, audience, canEdit, viewOnly = false, editRequest = 0, onRecordChange,
}: EmployeeContactCardProps): ReactElement {
  const [record, setRecord] = useState<ContactEmployee>(() => toContactRecord(employee));
  const [editing, setEditing] = useState(false);
  const [drafts, setDrafts] = useState<RowFieldDrafts | undefined>(undefined);
  const [state, setState] = useState<RowSaveState>(INITIAL_ROW_STATE);
  const containerRef = useRef<HTMLDivElement>(null);
  const editButtonRef = useRef<HTMLButtonElement>(null);
  const handledEditRequest = useRef(editRequest);
  // What to focus once the next render commits.
  const pendingFocus = useRef<'email' | 'edit-button' | null>(null);
  const scrollOnOpen = useRef(false);

  // Follow the page's copy of the employee when it changes, unless an edit is
  // open: the editor keeps the record its baselines came from.
  const editingRef = useRef(editing);
  editingRef.current = editing;
  useEffect(() => {
    if (!editingRef.current) setRecord(toContactRecord(employee));
  }, [employee]);

  useEffect(() => {
    const target = pendingFocus.current;
    if (!target) return;
    pendingFocus.current = null;
    if (target === 'email' && editing) {
      if (scrollOnOpen.current) {
        containerRef.current?.scrollIntoView?.({ block: 'start', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
      }
      containerRef.current?.querySelector<HTMLInputElement>('input[type="email"]')?.focus({ preventScroll: scrollOnOpen.current });
    } else if (target === 'edit-button' && !editing) {
      editButtonRef.current?.focus();
    }
    scrollOnOpen.current = false;
  }, [editing]);

  const startEditing = (fromElsewhere = false): void => {
    if (!canEdit) return;
    setDrafts(undefined);
    setState(INITIAL_ROW_STATE);
    pendingFocus.current = 'email';
    scrollOnOpen.current = fromElsewhere;
    setEditing(true);
  };

  const closeEditor = (): void => {
    pendingFocus.current = 'edit-button';
    setEditing(false);
    setDrafts(undefined);
  };

  useEffect(() => {
    if (editRequest === handledEditRequest.current) return;
    handledEditRequest.current = editRequest;
    if (!canEdit) return;
    if (editing) {
      containerRef.current?.querySelector<HTMLInputElement>('input[type="email"]')?.focus();
      return;
    }
    startEditing(true);
    // startEditing reads the latest props; this runs only for a new request.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editRequest, canEdit]);

  const draft = effectiveDraft(record, drafts);
  const dirty = hasAnyChangedField(drafts);

  // The page keeps its own copy of the employee; tell it about every newer
  // record so Cancel, the Employee app panel and other cards stay current.
  const shareRecord = (next: ContactEmployee, savedFields: ContactField[] = []): void => {
    onRecordChange?.(next, { emailChanged: (next.email ?? '') !== (employee.email ?? ''), savedFields });
  };

  const updateField = (field: ContactField, value: string): void => {
    setDrafts((prev) => editRowDraft(prev, record, field, value));
    setState((prev) => ({
      ...prev,
      saved: false,
      error: null,
      conflict: null,
      fieldErrors: { ...prev.fieldErrors, [field]: [] },
      ...(field === 'email' ? { samePersonRequired: false, samePersonChecked: false } : {}),
    }));
  };

  const cancel = (): void => {
    setState(INITIAL_ROW_STATE);
    closeEditor();
  };

  const save = async (options: { confirmSamePerson?: boolean; row?: RowFieldDrafts; against?: ContactEmployee } = {}): Promise<void> => {
    if (!canEdit) return;
    const row = options.row ?? drafts;
    const request = rowSaveRequest(row, options.against ?? record);
    const changedKeys = Object.keys(request.changes) as ContactField[];
    const confirmSamePerson = Boolean(options.confirmSamePerson || (state.samePersonRequired && state.samePersonChecked));
    if (changedKeys.length === 0 && !confirmSamePerson) return;

    setState((prev) => ({
      ...prev, saving: true, saved: false, submittedAddressRequestId: undefined, pendingAddressRequestId: undefined,
      error: null, fieldErrors: {}, conflict: null,
    }));

    const payload = {
      ...request.changes,
      row_revision: request.rowRevision,
      ...(changedKeys.length > 0 ? { baseline_values: request.baselineValues } : {}),
      ...(confirmSamePerson ? { confirm_same_person_email: true } : {}),
      response_view: 'contact' as const,
    };

    try {
      const response = audience === 'client'
        ? await clientEmployeesApi.update(record.id, payload)
        : await employeesApi.update(record.id, payload, companyId);
      const updated = toContactRecord(response.data);
      const addressRequest = 'change_request' in response && response.change_request?.profile_address ? response.change_request : null;
      setRecord(updated);
      setState({
        ...INITIAL_ROW_STATE,
        saved: true,
        submittedAddressRequestId: addressRequest?.id,
        warnings: response.contact_warnings ?? [],
      });
      closeEditor();
      shareRecord(updated, changedKeys);
    } catch (caught) {
      const conflict = extractConflictPayload(caught);
      if (conflict) {
        setState({
          ...INITIAL_ROW_STATE,
          error: conflict.error,
          conflict: {
            message: conflict.error,
            conflictingFields: conflict.conflicting_fields,
            serverEmployee: conflict.data,
            userChanges: request.changes,
          },
        });
        return;
      }
      const parsed = extractContactValidation(caught);
      setState((prev) => ({
        ...INITIAL_ROW_STATE,
        error: parsed.message,
        pendingAddressRequestId: parsed.pendingAddressRequestId,
        fieldErrors: parsed.fieldErrors,
        warnings: parsed.warnings,
        samePersonRequired: parsed.samePersonRequired,
        samePersonChecked: parsed.samePersonRequired ? prev.samePersonChecked : false,
      }));
    }
  };

  // Keep mine: resend only what was sent, against the newer record, so only
  // a deliberate second choice replaces what the other person saved.
  const keepMine = (): void => {
    const conflict = state.conflict;
    if (!conflict) return;
    const server = { ...record, ...conflict.serverEmployee };
    const row = keepMineRow(drafts, conflict);
    setRecord(server);
    setDrafts(row);
    shareRecord(server);
    void save({ row, against: server });
  };

  // Use theirs: show the newer record and drop the edits that collided. The
  // editor closes when nothing of mine is left to save.
  const chooseTheirs = (): void => {
    const conflict = state.conflict;
    if (!conflict) return;
    const server = { ...record, ...conflict.serverEmployee };
    const row = theirsWinRow(drafts, conflict);
    setRecord(server);
    setState(INITIAL_ROW_STATE);
    shareRecord(server);
    if (Object.keys(row).length === 0) closeEditor();
    else setDrafts(row);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>): void => {
    if (event.key !== 'Enter' || event.shiftKey) return;
    event.preventDefault();
    if (!state.saving && (dirty || (state.samePersonRequired && state.samePersonChecked))) void save();
  };

  const badge = contactStatusBadge(record);
  const otherWarnings = state.warnings.filter((warning) => warning.code !== 'shared_company_email');
  const name = `${record.first_name} ${record.last_name}`;

  return (
    <Card ref={containerRef} id="employee-contact" className="scroll-mt-4">
      <CardHeader className="flex flex-row flex-wrap items-start justify-between gap-4">
        <div className="min-w-0 space-y-2">
          <CardTitle>Contact</CardTitle>
          <div className="flex flex-wrap gap-1">
            <Badge variant={badge.variant}>{badge.label}</Badge>
            {record.email_verified_at && <Badge variant="success">Email confirmed</Badge>}
          </div>
        </div>
        {!editing && canEdit && (
          <Button ref={editButtonRef} variant="outline" size="sm" aria-label={`Edit contact for ${name}`} onClick={() => startEditing()} className="min-h-11 sm:min-h-9">
            <Pencil className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
            Edit
          </Button>
        )}
      </CardHeader>
      <CardContent className="space-y-4">
        {editing ? (
          <ContactEditor
            employee={record}
            draft={draft}
            phoneValue={drafts?.phone ? draft.phone : formatPhone(draft.phone)}
            state={state}
            canEdit={canEdit}
            dirty={dirty}
            onFieldChange={updateField}
            onKeyDown={handleKeyDown}
            onToggleSamePerson={(checked) => setState((prev) => ({ ...prev, samePersonChecked: checked }))}
            onConfirmSamePerson={() => void save({ confirmSamePerson: true })}
            onKeepMine={keepMine}
            onUseTheirs={chooseTheirs}
            onCancel={cancel}
            onSave={() => void save()}
          />
        ) : (
          <>
            <dl className="grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-3">
              <div className="min-w-0">
                <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Email</dt>
                <dd className="mt-1">
                  <ContactValue value={record.email} className="break-all" />
                  <SharedEmailNote employee={record} warnings={state.warnings} />
                </dd>
              </div>
              <div>
                <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Mobile</dt>
                <dd className="mt-1 tabular-nums">
                  <ContactValue value={formatPhone(record.phone)} />
                  {record.phone_confirmed_by_employee_at && <p className="mt-1 text-xs font-medium text-success-700">Confirmed by employee</p>}
                </dd>
              </div>
              <div className="min-w-0 sm:col-span-2 lg:col-span-1">
                <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Mailing address</dt>
                <dd className="mt-1 break-words"><AddressValue employee={record} /></dd>
              </div>
            </dl>
            {state.saved && (
              <p role="status" className="inline-flex items-center gap-1 text-sm font-semibold text-success-700">
                <ContactSaveResult requestId={state.submittedAddressRequestId} />
              </p>
            )}
            {otherWarnings.map((warning) => (
              <p key={`${warning.code}-${warning.message}`} role="status" className="flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 px-2 py-2 text-xs text-warning-900">
                <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning-700" aria-hidden="true" />
                <span>{warning.message}</span>
              </p>
            ))}
            {viewOnly && <ViewOnlyNotice />}
          </>
        )}
      </CardContent>
    </Card>
  );
}
