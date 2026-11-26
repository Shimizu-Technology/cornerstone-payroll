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
