import { toContactRecord } from '@/lib/employee-contact';
import { formatPhone } from '@/lib/display-phone';
import { contactEmailErrorMessage } from '@/lib/contact-email-errors';
import { ApiError } from '@/services/api';
import type {
  ContactEmployee,
  EmployeeContactConflictPayload,
  EmployeeContactValidationPayload,
  EmployeeContactWarning,
} from '@/types';

// Draft, save-state and error parsing shared by the Contact details grid and
// the employee page's Contact card (components/employees/ContactEditor.tsx).

export const CONTACT_FIELDS = ['email', 'phone', 'address_line1', 'address_line2', 'city', 'state', 'zip'] as const;
export type ContactField = (typeof CONTACT_FIELDS)[number];
export const ADDRESS_FIELDS: readonly ContactField[] = ['address_line1', 'address_line2', 'city', 'state', 'zip'];

export function hasAddressChanges(changes: ContactDraftPatch): boolean {
  return ADDRESS_FIELDS.some((field) => changes[field] !== undefined);
}

export const FIELD_LABELS: Record<ContactField, string> = {
  email: 'Email',
  phone: 'Mobile',
  address_line1: 'Street address',
  address_line2: 'Apt / Unit',
  city: 'City',
  state: 'State',
  zip: 'ZIP',
};

export interface ContactDraft {
  email: string;
  phone: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  zip: string;
}

export type ContactDraftPatch = Partial<ContactDraft>;

export interface RowConflictState {
  message: string;
  conflictingFields: string[];
  serverEmployee: ContactEmployee;
  userChanges: ContactDraftPatch;
}

export interface RowSaveState {
  saving: boolean;
  saved: boolean;
  submittedAddressRequestId?: number;
  pendingAddressRequestId?: number;
  error: string | null;
  fieldErrors: Record<string, string[]>;
  warnings: EmployeeContactWarning[];
  samePersonRequired: boolean;
  samePersonChecked: boolean;
  confirmingAddressReplacement?: boolean;
  conflict: RowConflictState | null;
}

export const INITIAL_ROW_STATE: RowSaveState = {
  saving: false,
  saved: false,
  error: null,
  fieldErrors: {},
  warnings: [],
  samePersonRequired: false,
  samePersonChecked: false,
  confirmingAddressReplacement: false,
  conflict: null,
};

export function baselineFromEmployee(employee: ContactEmployee): ContactDraft {
  return {
    email: employee.email ?? '',
    phone: employee.phone ?? '',
    address_line1: employee.address_line1 ?? '',
    address_line2: employee.address_line2 ?? '',
    city: employee.city ?? '',
    state: employee.state ?? '',
    zip: employee.zip ?? '',
  };
}

export function isFieldChanged(field: ContactField, value: string, baseline: string): boolean {
  if (field === 'phone') return formatPhone(value).trim() !== formatPhone(baseline).trim();
  return value.trim() !== baseline.trim();
}

export function extractConflictPayload(error: unknown): EmployeeContactConflictPayload | null {
  if (!(error instanceof ApiError) || error.status !== 409) return null;
  const raw = (error.data && typeof error.data === 'object') ? error.data as Record<string, unknown> : {};
  if (raw.code !== 'contact_revision_conflict' || !raw.data || typeof raw.data !== 'object') return null;

  return {
    error: typeof raw.error === 'string' ? raw.error : error.message,
    code: 'contact_revision_conflict',
    conflicting_fields: Array.isArray(raw.conflicting_fields)
      ? raw.conflicting_fields.filter((f): f is string => typeof f === 'string')
      : [],
    contact_revision: typeof raw.contact_revision === 'string' ? raw.contact_revision : '',
    current_values: (raw.current_values && typeof raw.current_values === 'object')
      ? raw.current_values as Record<string, string | null>
      : {},
    data: toContactRecord(raw.data as ContactEmployee),
  };
}

export function extractContactValidation(error: unknown): {
  fieldErrors: Record<string, string[]>;
  samePersonRequired: boolean;
  warnings: EmployeeContactWarning[];
  message: string;
  pendingAddressRequestId?: number;
} {
  if (error instanceof ApiError) {
    const raw = (error.data && typeof error.data === 'object') ? error.data as Record<string, unknown> : {};
    const contactValidation = (raw.contact_validation && typeof raw.contact_validation === 'object')
      ? raw.contact_validation as EmployeeContactValidationPayload
      : undefined;
    const fieldErrors: Record<string, string[]> = {};
    const rawErrors = (raw.errors && typeof raw.errors === 'object' && !Array.isArray(raw.errors))
      ? raw.errors as Record<string, unknown>
      : {};
    const sources = [rawErrors, error.details && typeof error.details === 'object' ? error.details : {}];
    for (const source of sources) {
      for (const [key, value] of Object.entries(source)) {
        if (Array.isArray(value)) {
          const strings = value.filter((item): item is string => typeof item === 'string');
          if (strings.length > 0) fieldErrors[key] = strings;
        }
      }
    }
    const emailReason = contactEmailErrorMessage(raw);
    if (emailReason && fieldErrors.email) fieldErrors.email = [emailReason];
    return {
      fieldErrors,
      samePersonRequired: Boolean(contactValidation?.same_person_confirmation_required),
      warnings: Array.isArray(contactValidation?.warnings) ? contactValidation.warnings : [],
      message: fieldErrors.base?.join(' ') || error.message,
      pendingAddressRequestId: raw.code === 'address_request_pending' && typeof raw.pending_request_id === 'number'
        ? raw.pending_request_id : undefined,
    };
  }
  return {
    fieldErrors: {},
    samePersonRequired: false,
    warnings: [],
    message: error instanceof Error ? error.message : 'Could not save contact details.',
  };
}

export function contactStatusBadge(employee: ContactEmployee): { label: string; variant: 'success' | 'warning' | 'danger' | 'info' } {
  const status = employee.contact_details_status;
  if (status?.email_issue === 'shared_inbox') {
    return { label: 'Shared email', variant: 'danger' };
  }
  if (status?.email_issue === 'placeholder') {
    return { label: 'Not a real email', variant: 'danger' };
  }
  if (status?.email_issue === 'placeholder_pattern') {
    return { label: 'Check this email', variant: 'warning' };
  }
  if (status?.needs_contact_details) {
    const missing = status.missing_fields;
    if (missing.length === 1) {
      const labelMap: Record<string, string> = {
        email: 'Missing email',
        phone: 'Missing mobile',
        address_line1: 'Missing street',
        city: 'Missing city',
        state: 'Missing state',
        zip: 'Missing ZIP',
      };
      return { label: labelMap[missing[0]] || 'Needs contact details', variant: 'warning' };
    }
    return { label: 'Missing details', variant: 'warning' };
  }
  if (status?.email_issue === 'shared_with_coworker') {
    return { label: 'Shared with a coworker', variant: 'info' };
  }
  return { label: 'Complete', variant: 'success' };
}

// Per-field drafts. Each edited field keeps the saved value and the row
// revision from when it was first edited, so a save only conflicts on a field
// someone else changed since, and a refetch never moves the baseline.
export interface ContactFieldDraft {
  value: string;
  baselineValue: string;
  baselineRevision: string;
}

export type RowFieldDrafts = Partial<Record<ContactField, ContactFieldDraft>>;
export type ContactDraftMap = Record<number, RowFieldDrafts>;

export function revisionOf(employee: ContactEmployee): string {
  return employee.contact_revision || employee.updated_at;
}

export function effectiveDraft(employee: ContactEmployee, rowDraft: RowFieldDrafts | undefined): ContactDraft {
  const merged = baselineFromEmployee(employee);
  if (!rowDraft) return merged;
  for (const field of CONTACT_FIELDS) {
    const entry = rowDraft[field];
    if (entry) merged[field] = entry.value;
  }
  return merged;
}

export function changedEntriesForRow(rowDraft: RowFieldDrafts | undefined): Array<[ContactField, ContactFieldDraft]> {
  if (!rowDraft) return [];
  const changed: Array<[ContactField, ContactFieldDraft]> = [];
  for (const field of CONTACT_FIELDS) {
    const entry = rowDraft[field];
    if (entry && isFieldChanged(field, entry.value, entry.baselineValue)) changed.push([field, entry]);
  }
  return changed;
}

export function hasAnyChangedField(rowDraft: RowFieldDrafts | undefined): boolean {
  return changedEntriesForRow(rowDraft).length > 0;
}

/**
 * The row's drafts after typing `value` into `field`. A field typed back to
 * its saved value is dropped, so it can't be sent later against a newer
 * baseline; the typed phone text is kept so formatting doesn't jump. Returns
 * undefined when nothing is left.
 */
export function editRowDraft(
  rowDraft: RowFieldDrafts | undefined, employee: ContactEmployee, field: ContactField, value: string,
): RowFieldDrafts | undefined {
  const row: RowFieldDrafts = { ...(rowDraft ?? {}) };
  const existing = row[field];
  const baselineValue = existing ? existing.baselineValue : baselineFromEmployee(employee)[field];
  const baselineRevision = existing ? existing.baselineRevision : revisionOf(employee);
  if (field !== 'phone' && !isFieldChanged(field, value, baselineValue)) delete row[field];
  else row[field] = { value, baselineValue, baselineRevision };
  return Object.keys(row).length > 0 ? row : undefined;
}

/**
 * What a save sends: the changed fields, each one's baseline, and the oldest
 * baseline revision that's behind the record shown, so the server checks
 * every changed field against what the editor started from.
 */
export function rowSaveRequest(rowDraft: RowFieldDrafts | undefined, employee: ContactEmployee): {
  changes: ContactDraftPatch;
  baselineValues: Record<string, string>;
  rowRevision: string;
} {
  const changedEntries = changedEntriesForRow(rowDraft);
  const currentRevision = revisionOf(employee);
  const changes: ContactDraftPatch = {};
  const baselineValues: Record<string, string> = {};
  let staleRevision: string | null = null;
  for (const [field, entry] of changedEntries) {
    changes[field] = entry.value.trim();
    baselineValues[field] = entry.baselineValue;
    if (entry.baselineRevision && entry.baselineRevision !== currentRevision) staleRevision ??= entry.baselineRevision;
  }
  return { changes, baselineValues, rowRevision: staleRevision ?? changedEntries[0]?.[1].baselineRevision ?? currentRevision };
}

/**
 * Keep mine: only the values that were sent are rebased onto the newer
 * record and resent. Anything else in the row wasn't a change, so it's
 * dropped rather than becoming one against the newer record.
 */
export function keepMineRow(rowDraft: RowFieldDrafts | undefined, conflict: RowConflictState): RowFieldDrafts {
  const server = baselineFromEmployee(conflict.serverEmployee);
  const serverRevision = revisionOf(conflict.serverEmployee);
  const rebased: RowFieldDrafts = {};
  for (const field of CONTACT_FIELDS) {
    const sent = conflict.userChanges[field];
    if (sent === undefined) continue;
    rebased[field] = { value: rowDraft?.[field]?.value ?? sent, baselineValue: server[field], baselineRevision: serverRevision };
  }
  return rebased;
}

/**
 * Use theirs: drop the edits that collided, and anything that wasn't sent.
 * The other sent edits keep their own baselines, which still match the
 * newer record, so saving them can't overwrite the other person.
 */
export function theirsWinRow(rowDraft: RowFieldDrafts | undefined, conflict: RowConflictState): RowFieldDrafts {
  const named = conflict.conflictingFields.filter((field): field is ContactField => CONTACT_FIELDS.includes(field as ContactField));
  const dropped = new Set<ContactField>(named.length > 0 ? named : (Object.keys(conflict.userChanges) as ContactField[]));
  const kept: RowFieldDrafts = {};
  for (const field of CONTACT_FIELDS) {
    const entry = rowDraft?.[field];
    if (entry && conflict.userChanges[field] !== undefined && !dropped.has(field)) kept[field] = entry;
  }
  return kept;
}
