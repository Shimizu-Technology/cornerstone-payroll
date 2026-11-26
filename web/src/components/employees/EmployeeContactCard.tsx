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
  CONTACT_FIELDS,
  INITIAL_ROW_STATE,
  baselineFromEmployee,
  contactStatusBadge,
  extractConflictPayload,
  extractContactValidation,
  isFieldChanged,
  type ContactDraft,
  type ContactDraftPatch,
  type ContactField,
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
  onSaved?: (updated: ContactEmployee, change: { emailChanged: boolean }) => void;
}

interface Baseline {
  values: ContactDraft;
  revision: string;
}

function revisionOf(employee: ContactEmployee): string {
  return employee.contact_revision || employee.updated_at;
}

// Email, mobile and mailing address on the employee page. Saves go through
// the same employee update endpoint as the Contact details grid, with the
// row revision and baseline values captured when Edit was opened, so a
// coworker's change in the meantime comes back as a conflict to resolve
// instead of being overwritten.
export function EmployeeContactCard({
  employee, companyId, audience, canEdit, viewOnly = false, editRequest = 0, onSaved,
}: EmployeeContactCardProps): ReactElement {
  const [record, setRecord] = useState<ContactEmployee>(() => toContactRecord(employee));
  const [editing, setEditing] = useState(false);
  const [baseline, setBaseline] = useState<Baseline | null>(null);
  const [drafts, setDrafts] = useState<ContactDraftPatch>({});
  const [state, setState] = useState<RowSaveState>(INITIAL_ROW_STATE);
  const containerRef = useRef<HTMLDivElement>(null);
  const handledEditRequest = useRef(editRequest);

  // Follow the page's copy of the employee while nothing is being edited.
  useEffect(() => {
    if (!editing) setRecord(toContactRecord(employee));
  }, [employee, editing]);

  const startEditing = (): void => {
    if (!canEdit) return;
    setBaseline({ values: baselineFromEmployee(record), revision: revisionOf(record) });
    setDrafts({});
    setState(INITIAL_ROW_STATE);
    setEditing(true);
  };

  useEffect(() => {
    if (editRequest === handledEditRequest.current) return;
    handledEditRequest.current = editRequest;
    if (!canEdit) return;
    if (!editing) startEditing();
    containerRef.current?.scrollIntoView?.({ block: 'start', behavior: 'smooth' });
    // Wait for the editor to render before focusing the email field.
    requestAnimationFrame(() => containerRef.current?.querySelector<HTMLInputElement>('input[type="email"]')?.focus({ preventScroll: true }));
    // startEditing reads the latest record; this runs only for a new request.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editRequest, canEdit]);

  const baselineValues = baseline?.values ?? baselineFromEmployee(record);
  const draft: ContactDraft = { ...baselineValues, ...drafts };
  const changedFields = CONTACT_FIELDS.filter((field) => drafts[field] !== undefined && isFieldChanged(field, drafts[field] ?? '', baselineValues[field]));
  const dirty = changedFields.length > 0;

  const updateField = (field: ContactField, value: string): void => {
    setDrafts((prev) => ({ ...prev, [field]: value }));
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
    setEditing(false);
    setBaseline(null);
    setDrafts({});
    setState(INITIAL_ROW_STATE);
  };

  const save = async (options: { confirmSamePerson?: boolean; changes?: ContactDraftPatch; against?: Baseline } = {}): Promise<void> => {
    if (!canEdit) return;
    const against = options.against ?? baseline ?? { values: baselineFromEmployee(record), revision: revisionOf(record) };
    const changes: ContactDraftPatch = options.changes ?? Object.fromEntries(changedFields.map((field) => [field, (drafts[field] ?? '').trim()]));
    const changedKeys = Object.keys(changes) as ContactField[];
    const confirmSamePerson = Boolean(options.confirmSamePerson || (state.samePersonRequired && state.samePersonChecked));
    if (changedKeys.length === 0 && !confirmSamePerson) return;

    setState((prev) => ({
      ...prev, saving: true, saved: false, submittedAddressRequestId: undefined, pendingAddressRequestId: undefined,
      error: null, fieldErrors: {}, conflict: null,
    }));

    const payload = {
      ...changes,
      row_revision: against.revision,
      ...(changedKeys.length > 0 ? { baseline_values: Object.fromEntries(changedKeys.map((field) => [field, against.values[field]])) } : {}),
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
      setEditing(false);
      setBaseline(null);
      setDrafts({});
      setState({
        ...INITIAL_ROW_STATE,
        saved: true,
        submittedAddressRequestId: addressRequest?.id,
        warnings: response.contact_warnings ?? [],
      });
      onSaved?.(updated, { emailChanged: (updated.email ?? '') !== (record.email ?? '') });
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
            userChanges: changes,
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

  // Keep mine: resend the same values against the newer record, so only a
  // deliberate second choice replaces what the other person saved.
  const keepMine = (): void => {
    const conflict = state.conflict;
    if (!conflict) return;
    const server = conflict.serverEmployee;
    const rebased = { values: baselineFromEmployee(server), revision: revisionOf(server) };
    setRecord((prev) => ({ ...prev, ...server }));
    setBaseline(rebased);
    void save({ changes: conflict.userChanges, against: rebased });
  };

  // Use theirs: show the newer record and drop only the edits that collided.
  const useTheirs = (): void => {
    const conflict = state.conflict;
    if (!conflict) return;
    const server = conflict.serverEmployee;
    const named = conflict.conflictingFields.filter((field): field is ContactField => CONTACT_FIELDS.includes(field as ContactField));
    const dropped = new Set<ContactField>(named.length > 0 ? named : (Object.keys(conflict.userChanges) as ContactField[]));
    setRecord((prev) => ({ ...prev, ...server }));
    setBaseline({ values: baselineFromEmployee(server), revision: revisionOf(server) });
    setDrafts((prev) => Object.fromEntries(Object.entries(prev).filter(([field]) => !dropped.has(field as ContactField))));
    setState(INITIAL_ROW_STATE);
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
          <Button variant="outline" size="sm" aria-label={`Edit contact for ${name}`} onClick={startEditing} className="min-h-11 sm:min-h-9">
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
            phoneValue={drafts.phone !== undefined ? draft.phone : formatPhone(draft.phone)}
            state={state}
            canEdit={canEdit}
            dirty={dirty}
            onFieldChange={updateField}
            onKeyDown={handleKeyDown}
            onToggleSamePerson={(checked) => setState((prev) => ({ ...prev, samePersonChecked: checked }))}
            onConfirmSamePerson={() => void save({ confirmSamePerson: true })}
            onKeepMine={keepMine}
            onUseTheirs={useTheirs}
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
