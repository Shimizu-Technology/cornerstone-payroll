import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router';
import {
  AlertCircle,
  AlertTriangle,
  ArrowLeft,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  RotateCcw,
  Save,
  Search,
  ShieldCheck,
} from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { MobileCardActions, MobileRecordCard } from '@/components/ui/mobile-record';
import { Select } from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteClientEmployeeProfile, canWriteCompany, companyReadOnlyMessage } from '@/lib/company-write-access';
import { employeesPath } from '@/lib/routes';
import { cn, getInitials } from '@/lib/utils';
import { ApiError, clientEmployeesApi, employeesApi } from '@/services/api';
import type {
  Employee,
  EmployeeContactConflictPayload,
  EmployeeContactValidationPayload,
  EmployeeContactWarning,
  PaginationMeta,
} from '@/types';

const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
const PER_PAGE = 50;

const CONTACT_FIELDS = ['email', 'phone', 'address_line1', 'address_line2', 'city', 'state', 'zip'] as const;
type ContactField = (typeof CONTACT_FIELDS)[number];

const FIELD_LABELS: Record<ContactField, string> = {
  email: 'Email',
  phone: 'Mobile',
  address_line1: 'Street address',
  address_line2: 'Apt / Unit',
  city: 'City',
  state: 'State',
  zip: 'ZIP',
};

function gridInputClass(extra = '', invalid = false): string {
  return cn(
    'block h-9 w-full rounded-lg border bg-white py-1.5 text-sm text-neutral-900 shadow-xs transition-[border-color,background-color,color,box-shadow] duration-150 ease-out placeholder:text-neutral-400 focus-visible:outline-none focus-visible:ring-2 disabled:cursor-not-allowed disabled:bg-neutral-50 disabled:text-neutral-500',
    invalid
      ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200'
      : 'border-neutral-300 focus-visible:border-primary-400 focus-visible:ring-primary-200',
    extra,
  );
}

interface ContactDraft {
  email: string;
  phone: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state: string;
  zip: string;
}

type ContactDraftPatch = Partial<ContactDraft>;

interface RowConflictState {
  message: string;
  conflictingFields: string[];
  serverEmployee: Employee;
  userChanges: ContactDraftPatch;
}

interface RowSaveState {
  saving: boolean;
  saved: boolean;
  error: string | null;
  fieldErrors: Record<string, string[]>;
  warnings: EmployeeContactWarning[];
  samePersonRequired: boolean;
  samePersonChecked: boolean;
  conflict: RowConflictState | null;
}

const INITIAL_ROW_STATE: RowSaveState = {
  saving: false,
  saved: false,
  error: null,
  fieldErrors: {},
  warnings: [],
  samePersonRequired: false,
  samePersonChecked: false,
  conflict: null,
};

function baselineFromEmployee(employee: Employee): ContactDraft {
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

function effectiveDraft(employee: Employee, patch: ContactDraftPatch | undefined): ContactDraft {
  const baseline = baselineFromEmployee(employee);
  return patch ? { ...baseline, ...patch } : baseline;
}

function changedFieldsForRow(employee: Employee, patch: ContactDraftPatch | undefined): ContactDraftPatch {
  if (!patch) return {};
  const baseline = baselineFromEmployee(employee);
  const changed: ContactDraftPatch = {};
  for (const field of CONTACT_FIELDS) {
    if (patch[field] !== undefined && patch[field].trim() !== baseline[field].trim()) {
      changed[field] = patch[field].trim();
    }
  }
  return changed;
}

function hasAnyChangedField(employee: Employee, patch: ContactDraftPatch | undefined): boolean {
  return Object.keys(changedFieldsForRow(employee, patch)).length > 0;
}

function extractConflictPayload(error: unknown): EmployeeContactConflictPayload | null {
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
    data: raw.data as Employee,
  };
}

function extractContactValidation(error: unknown): {
  fieldErrors: Record<string, string[]>;
  samePersonRequired: boolean;
  warnings: EmployeeContactWarning[];
  message: string;
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
    return {
      fieldErrors,
      samePersonRequired: Boolean(contactValidation?.same_person_confirmation_required),
      warnings: Array.isArray(contactValidation?.warnings) ? contactValidation.warnings : [],
      message: error.message,
    };
  }
  return {
    fieldErrors: {},
    samePersonRequired: false,
    warnings: [],
    message: error instanceof Error ? error.message : 'Could not save contact details.',
  };
}

function contactStatusBadge(employee: Employee): { label: string; variant: 'success' | 'warning' | 'danger' | 'info' } {
  const status = employee.contact_details_status;
  if (status?.email_issue === 'shared_inbox') {
    return { label: 'Shared inbox', variant: 'danger' };
  }
  if (status?.email_issue === 'placeholder') {
    return { label: 'Placeholder email', variant: 'danger' };
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
    return { label: 'Needs contact details', variant: 'warning' };
  }
  if (status?.email_issue === 'shared_with_coworker') {
    return { label: 'Shared with coworker', variant: 'info' };
  }
  return { label: 'Complete', variant: 'success' };
}

export interface EmployeeContactDetailsProps {
  /** Optional wrapper chrome (e.g. staff-only tabs) rendered above the grid. */
  topSlot?: ReactNode;
  /** Incrementing this triggers a reload of the current page while preserving pending edits. */
  refreshKey?: number;
  /** Callback notified when needs_contact_details_count updates. */
  onNeedsContactCountChange?: (count: number) => void;
  /** When true, omit the outer Header wrapper because a parent page renders it. */
  embedded?: boolean;
}

export function EmployeeContactDetails({
  topSlot,
  refreshKey = 0,
  onNeedsContactCountChange,
  embedded = false,
}: EmployeeContactDetailsProps = {}) {
  const [searchParams, setSearchParams] = useSearchParams();
  const { user, isClient } = useAuth();
  const { activeCompanyId, activeCompany } = useCompany();
  const companyId = activeCompanyId ?? user?.company_id ?? DEV_COMPANY_ID;
  const canEdit = isClient ? canWriteClientEmployeeProfile(activeCompany) : canWriteCompany(activeCompany);

  const search = searchParams.get('search') || '';
  const statusFilter = searchParams.get('status') ?? 'active';
  const needsContactOnly = searchParams.get('needs_contact_details') === 'true';
  const rawPage = parseInt(searchParams.get('page') || '1', 10);
  const page = Number.isFinite(rawPage) && rawPage >= 1 ? rawPage : 1;

  const [employees, setEmployees] = useState<Employee[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [loadedCompanyId, setLoadedCompanyId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  // Sparse per-field pending edits keyed by employee ID. Untouched fields always
  // reflect the latest server values on refetch, while pending edits survive
  // refetches and page navigation.
  const [drafts, setDrafts] = useState<Record<number, ContactDraftPatch>>({});
  const [rowStates, setRowStates] = useState<Record<number, RowSaveState>>({});
  const requestIdRef = useRef(0);
  const companyIdRef = useRef(companyId);

  useLayoutEffect(() => {
    companyIdRef.current = companyId;
    setIsLoading(true);
    setLoadError(null);
    setDrafts({});
    setRowStates({});
  }, [companyId]);

  const fetchEmployees = useCallback(async () => {
    const requestedCompanyId = companyId;
    if (requestedCompanyId !== companyIdRef.current) return;
    const requestId = ++requestIdRef.current;

    setIsLoading(true);
    setLoadError(null);
    try {
      const listParams = {
        search: search || undefined,
        status: statusFilter === 'all' ? undefined : (statusFilter || undefined),
        needs_contact_details: needsContactOnly ? true : undefined,
        page,
        per_page: PER_PAGE,
        sort_by: 'name' as const,
        sort_direction: 'asc' as const,
      };
      const payload = isClient
        ? await clientEmployeesApi.list(listParams)
        : await employeesApi.list({ company_id: requestedCompanyId, ...listParams });

      if (requestId !== requestIdRef.current || requestedCompanyId !== companyIdRef.current) return;
      setEmployees(payload.data);
      setMeta(payload.meta);
      setLoadedCompanyId(requestedCompanyId);
      // Clean up any draft field whose value already matches the refreshed server baseline,
      // while preserving all other user-edited fields (including edits on other pages).
      setDrafts((prev) => {
        let changed = false;
        const next: Record<number, ContactDraftPatch> = { ...prev };
        for (const emp of payload.data) {
          const patch = next[emp.id];
          if (!patch) continue;
          const remaining = changedFieldsForRow(emp, patch);
          if (Object.keys(remaining).length === 0) {
            delete next[emp.id];
            changed = true;
          }
        }
        return changed ? next : prev;
      });
    } catch (caught) {
      if (requestId !== requestIdRef.current || requestedCompanyId !== companyIdRef.current) return;
      setLoadError(caught instanceof Error ? caught.message : 'Could not load employee contact details.');
    } finally {
      if (requestId === requestIdRef.current && requestedCompanyId === companyIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [companyId, isClient, needsContactOnly, page, search, statusFilter]);

  useEffect(() => {
    void fetchEmployees();
  }, [fetchEmployees, refreshKey]);

  const updateFilter = (key: string, value: string, replace = false) => {
    const next = new URLSearchParams(searchParams);
    if (value) next.set(key, value);
    else next.delete(key);
    if (key !== 'page') next.delete('page');
    setSearchParams(next, { replace });
  };

  const setPage = (nextPage: number) => {
    const clamped = Math.max(1, Math.min(nextPage, meta?.total_pages || nextPage));
    updateFilter('page', clamped <= 1 ? '' : String(clamped));
  };

  const companyEmployees = useMemo(
    () => (loadedCompanyId === companyId ? employees : []),
    [companyId, employees, loadedCompanyId],
  );

  const employeesById = useMemo(() => {
    const map = new Map<number, Employee>();
    for (const emp of companyEmployees) map.set(emp.id, emp);
    return map;
  }, [companyEmployees]);

  const dirtyCount = useMemo(() => {
    let count = 0;
    for (const [idStr, patch] of Object.entries(drafts)) {
      const id = Number(idStr);
      const emp = employeesById.get(id);
      if (emp) {
        if (hasAnyChangedField(emp, patch)) count += 1;
      } else if (Object.keys(patch).length > 0) {
        // Pending edits on another page are kept and counted too.
        count += 1;
      }
    }
    return count;
  }, [drafts, employeesById]);

  const needsContactCount = meta?.needs_contact_details_count
    ?? companyEmployees.filter((emp) => emp.contact_details_status?.needs_contact_details).length;

  useEffect(() => {
    onNeedsContactCountChange?.(needsContactCount);
  }, [needsContactCount, onNeedsContactCountChange]);

  const updateDraftField = (employee: Employee, field: ContactField, value: string) => {
    const baseline = baselineFromEmployee(employee);
    setDrafts((prev) => {
      const existing = { ...(prev[employee.id] ?? {}) };
      if (value.trim() === baseline[field].trim()) {
        delete existing[field];
      } else {
        existing[field] = value;
      }
      if (Object.keys(existing).length === 0) {
        const next = { ...prev };
        delete next[employee.id];
        return next;
      }
      return { ...prev, [employee.id]: existing };
    });
    setRowStates((prev) => {
      const current = prev[employee.id];
      if (!current) return prev;
      return {
        ...prev,
        [employee.id]: {
          ...current,
          saved: false,
          error: null,
          conflict: null,
          fieldErrors: { ...current.fieldErrors, [field]: [] },
          ...(field === 'email' ? { samePersonRequired: false, samePersonChecked: false } : {}),
        },
      };
    });
  };

  const resetRow = (employee: Employee) => {
    setDrafts((prev) => {
      if (!prev[employee.id]) return prev;
      const next = { ...prev };
      delete next[employee.id];
      return next;
    });
    setRowStates((prev) => ({ ...prev, [employee.id]: INITIAL_ROW_STATE }));
  };

  const toggleSamePersonCheck = (employeeId: number, checked: boolean) => {
    setRowStates((prev) => ({
      ...prev,
      [employeeId]: {
        ...(prev[employeeId] ?? INITIAL_ROW_STATE),
        samePersonChecked: checked,
      },
    }));
  };

  const saveRow = async (
    employee: Employee,
    options: { explicitConfirmSamePerson?: boolean; overrideBaselineEmployee?: Employee; overrideChanges?: ContactDraftPatch } = {},
  ) => {
    if (!canEdit) return;
    const baseEmployee = options.overrideBaselineEmployee ?? employee;
    const changes = options.overrideChanges ?? changedFieldsForRow(baseEmployee, drafts[employee.id]);
    const currentState = rowStates[employee.id] ?? INITIAL_ROW_STATE;
    const confirmSamePerson = Boolean(
      options.explicitConfirmSamePerson || (currentState.samePersonRequired && currentState.samePersonChecked),
    );
    const changedKeys = Object.keys(changes) as ContactField[];
    if (changedKeys.length === 0 && !confirmSamePerson) return;

    const baseline = baselineFromEmployee(baseEmployee);
    const baselineValues: Record<string, string> = {};
    for (const key of changedKeys) {
      baselineValues[key] = baseline[key];
    }

    setRowStates((prev) => ({
      ...prev,
      [employee.id]: {
        ...(prev[employee.id] ?? INITIAL_ROW_STATE),
        saving: true,
        saved: false,
        error: null,
        fieldErrors: {},
        conflict: null,
      },
    }));

    const payload = {
      ...changes,
      row_revision: baseEmployee.contact_revision || baseEmployee.updated_at,
      ...(changedKeys.length > 0 ? { baseline_values: baselineValues } : {}),
      ...(confirmSamePerson ? { confirm_same_person_email: true } : {}),
    };

    try {
      const response = isClient
        ? await clientEmployeesApi.update(employee.id, payload)
        : await employeesApi.update(employee.id, payload, companyId);

      const updated = response.data;
      const warnings = response.contact_warnings ?? [];

      setEmployees((prev) => prev.map((item) => (item.id === updated.id ? { ...item, ...updated } : item)));
      setDrafts((prev) => {
        if (!prev[updated.id]) return prev;
        const next = { ...prev };
        delete next[updated.id];
        return next;
      });
      setRowStates((prev) => ({
        ...prev,
        [updated.id]: {
          saving: false,
          saved: true,
          error: null,
          fieldErrors: {},
          warnings,
          samePersonRequired: false,
          samePersonChecked: false,
          conflict: null,
        },
      }));

      const wasNeeding = baseEmployee.contact_details_status?.needs_contact_details ?? false;
      const nowNeeding = updated.contact_details_status?.needs_contact_details ?? false;
      if (wasNeeding !== nowNeeding) {
        setMeta((prev) => prev && typeof prev.needs_contact_details_count === 'number'
          ? { ...prev, needs_contact_details_count: Math.max(0, prev.needs_contact_details_count + (nowNeeding ? 1 : -1)) }
          : prev);
      }
    } catch (caught) {
      const conflictPayload = extractConflictPayload(caught);
      if (conflictPayload) {
        setRowStates((prev) => ({
          ...prev,
          [employee.id]: {
            saving: false,
            saved: false,
            error: conflictPayload.error,
            fieldErrors: {},
            warnings: [],
            samePersonRequired: false,
            samePersonChecked: false,
            conflict: {
              message: conflictPayload.error,
              conflictingFields: conflictPayload.conflicting_fields,
              serverEmployee: conflictPayload.data,
              userChanges: changes,
            },
          },
        }));
        return;
      }

      const parsed = extractContactValidation(caught);
      setRowStates((prev) => ({
        ...prev,
        [employee.id]: {
          saving: false,
          saved: false,
          error: parsed.message,
          fieldErrors: parsed.fieldErrors,
          warnings: parsed.warnings,
          samePersonRequired: parsed.samePersonRequired,
          samePersonChecked: parsed.samePersonRequired ? Boolean(prev[employee.id]?.samePersonChecked) : false,
          conflict: null,
        },
      }));
    }
  };

  const handleKeepMyVersion = (employee: Employee) => {
    const conflict = rowStates[employee.id]?.conflict;
    if (!conflict) return;
    // Update the row's server baseline (refreshing untouched fields and revision)
    // and re-submit only the user's edited fields.
    setEmployees((prev) => prev.map((item) => (item.id === employee.id ? { ...item, ...conflict.serverEmployee } : item)));
    void saveRow(employee, {
      overrideBaselineEmployee: conflict.serverEmployee,
      overrideChanges: conflict.userChanges,
    });
  };

  const handleDiscardMyVersion = (employee: Employee) => {
    const conflict = rowStates[employee.id]?.conflict;
    if (!conflict) return;
    setEmployees((prev) => prev.map((item) => (item.id === employee.id ? { ...item, ...conflict.serverEmployee } : item)));
    resetRow(employee);
  };

  const handleRowKeyDown = (event: KeyboardEvent<HTMLInputElement>, employee: Employee) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
      if (!state.saving && (hasAnyChangedField(employee, drafts[employee.id]) || (state.samePersonRequired && state.samePersonChecked))) {
        void saveRow(employee);
      }
    }
  };

  const totalCount = meta?.total_count ?? companyEmployees.length;
  const currentPage = meta?.current_page ?? page;
  const totalPages = meta?.total_pages ?? 1;
  const perPage = meta?.per_page ?? PER_PAGE;
  const rangeStart = totalCount === 0 ? 0 : (currentPage - 1) * perPage + 1;
  const rangeEnd = totalCount === 0 ? 0 : Math.min(currentPage * perPage, totalCount);

  const gridBody = (
    <>
      {topSlot}

      {!canEdit && (
        <Alert tone="info">{companyReadOnlyMessage(activeCompany)}</Alert>
      )}

      {/* Summary strip + filter bar */}
      <div className="flex flex-col gap-4 rounded-xl border border-neutral-200 bg-white p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              aria-pressed={needsContactOnly}
              onClick={() => updateFilter('needs_contact_details', needsContactOnly ? '' : 'true')}
              className={cn(
                'inline-flex min-h-10 items-center gap-2 rounded-full border px-3.5 text-sm font-semibold transition',
                needsContactOnly
                  ? 'border-warning-400 bg-warning-100 text-warning-950 shadow-sm'
                  : 'border-neutral-300 bg-white text-neutral-700 hover:border-warning-300 hover:bg-warning-50',
              )}
            >
              <AlertTriangle className="h-4 w-4 text-warning-700" aria-hidden="true" />
              Needs contact details
              <span className="rounded-full bg-white/90 px-2 py-0.5 text-xs font-bold tabular-nums text-warning-900">
                {needsContactCount}
              </span>
            </button>

            {needsContactOnly && (
              <button
                type="button"
                onClick={() => updateFilter('needs_contact_details', '')}
                className="text-sm font-semibold text-primary-700 underline-offset-2 hover:underline"
              >
                Show all
              </button>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-3 text-xs text-neutral-600">
            <span>
              {totalPages > 1 ? (
                <>
                  Showing <strong className="tabular-nums text-neutral-900">{rangeStart}–{rangeEnd}</strong> of{' '}
                  <strong className="tabular-nums text-neutral-900">{totalCount}</strong> employees
                </>
              ) : (
                <>
                  Showing <strong className="tabular-nums text-neutral-900">{totalCount}</strong>{' '}
                  {totalCount === 1 ? 'employee' : 'employees'}
                </>
              )}
            </span>
            {dirtyCount > 0 && (
              <Badge variant="info">{dirtyCount} unsaved {dirtyCount === 1 ? 'row' : 'rows'}</Badge>
            )}
          </div>
        </div>

        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <div className="relative w-full sm:w-72">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" aria-hidden="true" />
            <Input
              type="text"
              aria-label="Search employees"
              placeholder="Search by name or email..."
              value={search}
              onChange={(event) => updateFilter('search', event.target.value, true)}
              className="pl-10"
            />
          </div>

          <Select
            aria-label="Employee status"
            value={statusFilter}
            onChange={(event) => updateFilter('status', event.target.value)}
            className="w-full sm:w-40"
          >
            <option value="active">Active</option>
            <option value="all">All status</option>
            <option value="inactive">Inactive</option>
            <option value="terminated">Terminated</option>
          </Select>

          <p className="text-xs text-neutral-500 sm:ml-auto">
            7-digit Guam numbers default to <span className="font-mono font-medium text-neutral-700">+1 671</span>. Press <kbd className="rounded border border-neutral-300 bg-neutral-50 px-1.5 py-0.5 font-mono text-[11px] text-neutral-700">Enter</kbd> in a row to save.
          </p>
        </div>
      </div>

      {loadError && (
        <Alert tone="error" className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <span>{loadError}</span>
          <Button variant="outline" size="sm" onClick={() => void fetchEmployees()}>
            Retry
          </Button>
        </Alert>
      )}

      {isLoading ? (
        <div className="flex items-center justify-center py-12">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary-600" />
        </div>
      ) : companyEmployees.length === 0 ? (
        <Card className="p-10 text-center">
          <CheckCircle2 className="mx-auto h-10 w-10 text-success-600" aria-hidden="true" />
          <h2 className="mt-3 text-base font-semibold text-neutral-900">
            {needsContactOnly ? 'Everyone in this view has contact details' : 'No employees match these filters'}
          </h2>
          <p className="mt-1 text-sm text-neutral-600">
            {needsContactOnly
              ? 'Switch off the Needs contact details filter to review or update all employees.'
              : 'Try clearing your search or changing the status filter.'}
          </p>
          {needsContactOnly && (
            <div className="mt-4">
              <Button variant="outline" size="sm" onClick={() => updateFilter('needs_contact_details', '')}>
                Show all employees
              </Button>
            </div>
          )}
        </Card>
      ) : (
        <>
          {/* Desktop editable grid */}
          <Card className="hidden overflow-hidden lg:block">
            <Table stickyHeader>
              <TableHeader>
                <TableRow>
                  <TableHead stickyLeft className="w-[168px] px-3 uppercase tracking-wider">Employee</TableHead>
                  <TableHead className="w-[205px] px-2 uppercase tracking-wider">Email</TableHead>
                  <TableHead className="w-[144px] px-2 uppercase tracking-wider">Mobile</TableHead>
                  <TableHead className="min-w-[235px] px-2 uppercase tracking-wider">Mailing address</TableHead>
                  <TableHead className="w-[94px] px-2.5 text-right uppercase tracking-wider">Action</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {companyEmployees.map((employee, index) => {
                  const draft = effectiveDraft(employee, drafts[employee.id]);
                  const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
                  const dirty = hasAnyChangedField(employee, drafts[employee.id]);
                  const badge = contactStatusBadge(employee);
                  const rowBg = index % 2 === 0 ? 'bg-white' : 'bg-neutral-50/70';

                  return (
                    <TableRow key={employee.id} className={cn(rowBg, 'align-top')}>
                      <TableCell stickyLeft className={cn(rowBg, 'whitespace-normal px-3 py-3')}>
                        <div className="flex items-start gap-2">
                          <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary-100 text-[11px] font-semibold text-primary-700">
                            {getInitials(employee.first_name, employee.last_name)}
                          </div>
                          <div className="min-w-0 space-y-1">
                            <p className="text-sm font-semibold text-neutral-950 leading-snug">
                              {employee.first_name} {employee.last_name}
                            </p>
                            <div className="flex flex-wrap gap-1">
                              <Badge variant={badge.variant}>{badge.label}</Badge>
                              {employee.email_verified_at && (
                                <Badge variant="success">Verified</Badge>
                              )}
                            </div>
                          </div>
                        </div>
                      </TableCell>

                      <TableCell className="whitespace-normal px-2 py-3">
                        <input
                          type="email"
                          aria-label={`Email for ${employee.first_name} ${employee.last_name}`}
                          value={draft.email}
                          disabled={!canEdit || state.saving}
                          placeholder="name@example.com"
                          onChange={(event) => updateDraftField(employee, 'email', event.target.value)}
                          onKeyDown={(event) => handleRowKeyDown(event, employee)}
                          className={gridInputClass('px-2.5', Boolean(state.fieldErrors.email?.length))}
                        />
                        <RowInlineFeedback
                          employee={employee}
                          state={state}
                          field="email"
                          canEdit={canEdit}
                          onToggleSamePerson={(checked) => toggleSamePersonCheck(employee.id, checked)}
                          onConfirmAndSave={() => void saveRow(employee, { explicitConfirmSamePerson: true })}
                        />
                      </TableCell>

                      <TableCell className="whitespace-normal px-2 py-3">
                        <input
                          type="tel"
                          aria-label={`Mobile for ${employee.first_name} ${employee.last_name}`}
                          value={draft.phone}
                          disabled={!canEdit || state.saving}
                          placeholder="671-555-0100"
                          onChange={(event) => updateDraftField(employee, 'phone', event.target.value)}
                          onKeyDown={(event) => handleRowKeyDown(event, employee)}
                          className={gridInputClass('px-2 tabular-nums', Boolean(state.fieldErrors.phone?.length))}
                        />
                        {state.fieldErrors.phone?.map((msg) => (
                          <p key={msg} role="alert" className="mt-1 text-xs text-danger-700">{msg}</p>
                        ))}
                        {employee.phone_confirmed_by_employee_at && !dirty && (
                          <p className="mt-1 text-[11px] font-medium text-success-700">Confirmed by employee</p>
                        )}
                      </TableCell>

                      <TableCell className="whitespace-normal px-2 py-3">
                        <div className="space-y-1.5">
                          <div className="grid grid-cols-[minmax(0,1fr)_72px] gap-1.5">
                            <input
                              type="text"
                              aria-label={`Street address for ${employee.first_name} ${employee.last_name}`}
                              value={draft.address_line1}
                              disabled={!canEdit || state.saving}
                              placeholder="Street address"
                              onChange={(event) => updateDraftField(employee, 'address_line1', event.target.value)}
                              onKeyDown={(event) => handleRowKeyDown(event, employee)}
                              className={gridInputClass('px-2', Boolean(state.fieldErrors.address_line1?.length))}
                            />
                            <input
                              type="text"
                              aria-label={`Apt or unit for ${employee.first_name} ${employee.last_name}`}
                              value={draft.address_line2}
                              disabled={!canEdit || state.saving}
                              placeholder="Apt / Unit"
                              onChange={(event) => updateDraftField(employee, 'address_line2', event.target.value)}
                              onKeyDown={(event) => handleRowKeyDown(event, employee)}
                              className={gridInputClass('px-2')}
                            />
                          </div>
                          <div className="grid grid-cols-[minmax(0,1fr)_46px_70px] gap-1.5">
                            <input
                              type="text"
                              aria-label={`City for ${employee.first_name} ${employee.last_name}`}
                              value={draft.city}
                              disabled={!canEdit || state.saving}
                              placeholder="City"
                              onChange={(event) => updateDraftField(employee, 'city', event.target.value)}
                              onKeyDown={(event) => handleRowKeyDown(event, employee)}
                              className={gridInputClass('px-2', Boolean(state.fieldErrors.city?.length))}
                            />
                            <input
                              type="text"
                              aria-label={`State for ${employee.first_name} ${employee.last_name}`}
                              value={draft.state}
                              disabled={!canEdit || state.saving}
                              placeholder="GU"
                              maxLength={2}
                              onChange={(event) => updateDraftField(employee, 'state', event.target.value.toUpperCase())}
                              onKeyDown={(event) => handleRowKeyDown(event, employee)}
                              className={gridInputClass('px-1 text-center uppercase', Boolean(state.fieldErrors.state?.length))}
                            />
                            <input
                              type="text"
                              aria-label={`ZIP for ${employee.first_name} ${employee.last_name}`}
                              value={draft.zip}
                              disabled={!canEdit || state.saving}
                              placeholder="96910"
                              onChange={(event) => updateDraftField(employee, 'zip', event.target.value)}
                              onKeyDown={(event) => handleRowKeyDown(event, employee)}
                              className={gridInputClass('px-2 tabular-nums', Boolean(state.fieldErrors.zip?.length))}
                            />
                          </div>
                        </div>
                        {state.conflict && (
                          <RowConflictBanner
                            conflict={state.conflict}
                            saving={state.saving}
                            onKeep={() => handleKeepMyVersion(employee)}
                            onDiscard={() => handleDiscardMyVersion(employee)}
                          />
                        )}
                      </TableCell>

                      <TableCell className="px-2.5 py-3 text-right">
                        <div className="flex flex-col items-end gap-1.5">
                          <div className="flex items-center gap-1.5">
                            {dirty && (
                              <Button
                                variant="ghost"
                                size="sm"
                                aria-label={`Reset ${employee.first_name} ${employee.last_name}`}
                                disabled={state.saving}
                                onClick={() => resetRow(employee)}
                              >
                                <RotateCcw className="h-3.5 w-3.5" aria-hidden="true" />
                              </Button>
                            )}
                            <Button
                              size="sm"
                              variant={dirty || (state.samePersonRequired && state.samePersonChecked) ? 'primary' : 'outline'}
                              disabled={!canEdit || state.saving || (!dirty && !(state.samePersonRequired && state.samePersonChecked))}
                              loading={state.saving}
                              loadingLabel="Saving"
                              aria-label={`Save ${employee.first_name} ${employee.last_name}`}
                              onClick={() => void saveRow(employee)}
                            >
                              <Save className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />
                              Save
                            </Button>
                          </div>
                          {state.saved && !dirty && (
                            <span role="status" className="inline-flex items-center gap-1 text-xs font-semibold text-success-700">
                              <Check className="h-3.5 w-3.5" aria-hidden="true" />
                              Saved
                            </span>
                          )}
                          {state.error && !state.conflict && !state.samePersonRequired && !state.fieldErrors.email?.length && !state.fieldErrors.phone?.length && (
                            <p role="alert" className="max-w-[180px] whitespace-normal text-right text-xs text-danger-700">
                              {state.error}
                            </p>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </Card>

          {/* Mobile & tablet cards */}
          <div className="space-y-4 lg:hidden">
            {companyEmployees.map((employee) => {
              const draft = effectiveDraft(employee, drafts[employee.id]);
              const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
              const dirty = hasAnyChangedField(employee, drafts[employee.id]);
              const badge = contactStatusBadge(employee);

              return (
                <MobileRecordCard key={employee.id}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="flex items-center gap-3 min-w-0">
                      <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary-100 text-sm font-semibold text-primary-700">
                        {getInitials(employee.first_name, employee.last_name)}
                      </div>
                      <div className="min-w-0">
                        <h2 className="truncate font-semibold text-neutral-950">
                          {employee.first_name} {employee.last_name}
                        </h2>
                        <div className="mt-1 flex flex-wrap gap-1.5">
                          <Badge variant={badge.variant}>{badge.label}</Badge>
                          {employee.email_verified_at && <Badge variant="success">Verified</Badge>}
                        </div>
                      </div>
                    </div>
                    {state.saved && !dirty && (
                      <span role="status" className="inline-flex shrink-0 items-center gap-1 text-xs font-semibold text-success-700">
                        <Check className="h-3.5 w-3.5" aria-hidden="true" />
                        Saved
                      </span>
                    )}
                  </div>

                  <div className="mt-4 space-y-3">
                    <div>
                      <Input
                        label="Email"
                        type="email"
                        value={draft.email}
                        disabled={!canEdit || state.saving}
                        placeholder="name@example.com"
                        error={state.samePersonRequired ? undefined : state.fieldErrors.email?.[0]}
                        onChange={(event) => updateDraftField(employee, 'email', event.target.value)}
                        onKeyDown={(event) => handleRowKeyDown(event, employee)}
                      />
                      <RowInlineFeedback
                        employee={employee}
                        state={state}
                        field="email"
                        hidePrimaryFieldError={!state.samePersonRequired}
                        canEdit={canEdit}
                        onToggleSamePerson={(checked) => toggleSamePersonCheck(employee.id, checked)}
                        onConfirmAndSave={() => void saveRow(employee, { explicitConfirmSamePerson: true })}
                      />
                    </div>

                    <Input
                      label="Mobile number"
                      type="tel"
                      value={draft.phone}
                      disabled={!canEdit || state.saving}
                      placeholder="671-555-0100"
                      error={state.fieldErrors.phone?.[0]}
                      helperText={employee.phone_confirmed_by_employee_at && !dirty ? 'Confirmed by employee' : undefined}
                      onChange={(event) => updateDraftField(employee, 'phone', event.target.value)}
                      onKeyDown={(event) => handleRowKeyDown(event, employee)}
                    />

                    <Input
                      label="Street address"
                      value={draft.address_line1}
                      disabled={!canEdit || state.saving}
                      placeholder="Street address"
                      error={state.fieldErrors.address_line1?.[0]}
                      onChange={(event) => updateDraftField(employee, 'address_line1', event.target.value)}
                      onKeyDown={(event) => handleRowKeyDown(event, employee)}
                    />

                    <Input
                      label="Apt / Unit (optional)"
                      value={draft.address_line2}
                      disabled={!canEdit || state.saving}
                      placeholder="Apt, suite, or box"
                      onChange={(event) => updateDraftField(employee, 'address_line2', event.target.value)}
                      onKeyDown={(event) => handleRowKeyDown(event, employee)}
                    />

                    <div className="grid grid-cols-[minmax(0,1fr)_72px_104px] gap-2">
                      <Input
                        label="City"
                        value={draft.city}
                        disabled={!canEdit || state.saving}
                        placeholder="Hagatna"
                        error={state.fieldErrors.city?.[0]}
                        onChange={(event) => updateDraftField(employee, 'city', event.target.value)}
                        onKeyDown={(event) => handleRowKeyDown(event, employee)}
                      />
                      <Input
                        label="State"
                        value={draft.state}
                        maxLength={2}
                        disabled={!canEdit || state.saving}
                        placeholder="GU"
                        error={state.fieldErrors.state?.[0]}
                        onChange={(event) => updateDraftField(employee, 'state', event.target.value.toUpperCase())}
                        onKeyDown={(event) => handleRowKeyDown(event, employee)}
                      />
                      <Input
                        label="ZIP"
                        value={draft.zip}
                        disabled={!canEdit || state.saving}
                        placeholder="96910"
                        error={state.fieldErrors.zip?.[0]}
                        onChange={(event) => updateDraftField(employee, 'zip', event.target.value)}
                        onKeyDown={(event) => handleRowKeyDown(event, employee)}
                      />
                    </div>

                    {state.conflict && (
                      <RowConflictBanner
                        conflict={state.conflict}
                        saving={state.saving}
                        onKeep={() => handleKeepMyVersion(employee)}
                        onDiscard={() => handleDiscardMyVersion(employee)}
                      />
                    )}

                    {state.error && !state.conflict && !state.samePersonRequired && !state.fieldErrors.email?.length && !state.fieldErrors.phone?.length && (
                      <Alert tone="error">{state.error}</Alert>
                    )}
                  </div>

                  <MobileCardActions>
                    <Button
                      disabled={!canEdit || state.saving || (!dirty && !(state.samePersonRequired && state.samePersonChecked))}
                      loading={state.saving}
                      loadingLabel="Saving..."
                      onClick={() => void saveRow(employee)}
                      className="w-full sm:w-auto"
                    >
                      <Save className="mr-1.5 h-4 w-4" aria-hidden="true" />
                      Save contact details
                    </Button>
                    {dirty && (
                      <Button
                        variant="outline"
                        disabled={state.saving}
                        onClick={() => resetRow(employee)}
                        className="w-full sm:w-auto"
                      >
                        Reset changes
                      </Button>
                    )}
                  </MobileCardActions>
                </MobileRecordCard>
              );
            })}
          </div>

          {totalPages > 1 && (
            <nav
              aria-label="Contact details pagination"
              className="flex flex-col items-center justify-between gap-3 rounded-xl border border-neutral-200 bg-white px-4 py-3 sm:flex-row"
            >
              <p className="text-sm text-neutral-600">
                Page <strong className="tabular-nums text-neutral-900">{currentPage}</strong> of{' '}
                <strong className="tabular-nums text-neutral-900">{totalPages}</strong>{' '}
                <span className="text-neutral-500">({rangeStart}–{rangeEnd} of {totalCount})</span>
              </p>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  disabled={currentPage <= 1 || isLoading}
                  onClick={() => setPage(currentPage - 1)}
                >
                  <ChevronLeft className="mr-1 h-4 w-4" aria-hidden="true" />
                  Previous
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={currentPage >= totalPages || isLoading}
                  onClick={() => setPage(currentPage + 1)}
                >
                  Next
                  <ChevronRight className="ml-1 h-4 w-4" aria-hidden="true" />
                </Button>
              </div>
            </nav>
          )}
        </>
      )}
    </>
  );

  if (embedded) {
    return gridBody;
  }

  return (
    <div>
      <Header
        title="Contact Details"
        description="Set and update every employee's own email, mobile number, and mailing address in one place."
        actions={
          <Link
            to={employeesPath(companyId)}
            className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:bg-primary-50/60 hover:text-primary-800 sm:min-h-10"
          >
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
            All employees
          </Link>
        }
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {gridBody}
      </div>
    </div>
  );
}

function RowConflictBanner({
  conflict,
  saving,
  onKeep,
  onDiscard,
}: {
  conflict: RowConflictState;
  saving: boolean;
  onKeep: () => void;
  onDiscard: () => void;
}) {
  const fieldsToShow = conflict.conflictingFields.filter(
    (field): field is ContactField => CONTACT_FIELDS.includes(field as ContactField),
  );
  const serverValues = baselineFromEmployee(conflict.serverEmployee);

  return (
    <div role="alert" className="mt-2 rounded-lg border border-warning-300 bg-warning-50 p-3 text-xs text-warning-950">
      <p className="flex items-start gap-1.5 font-semibold">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
        <span>Conflict: someone else updated this row before you saved.</span>
      </p>
      <p className="mt-1 text-warning-900">{conflict.message}</p>
      {fieldsToShow.length > 0 && (
        <ul className="mt-2 space-y-1 rounded-md border border-warning-200 bg-white/80 p-2 text-neutral-800">
          {fieldsToShow.map((field) => (
            <li key={field}>
              <strong>{FIELD_LABELS[field]}:</strong> current saved value is{' '}
              <span className="font-mono">{serverValues[field] || '(blank)'}</span>; your draft is{' '}
              <span className="font-mono">{conflict.userChanges[field] || '(blank)'}</span>.
            </li>
          ))}
        </ul>
      )}
      <div className="mt-2.5 flex flex-wrap gap-2">
        <Button size="sm" variant="primary" disabled={saving} loading={saving} loadingLabel="Saving..." onClick={onKeep}>
          Keep my changes
        </Button>
        <Button size="sm" variant="outline" disabled={saving} onClick={onDiscard}>
          Discard my changes
        </Button>
      </div>
    </div>
  );
}

function RowInlineFeedback({
  employee,
  state,
  field,
  hidePrimaryFieldError = false,
  canEdit,
  onToggleSamePerson,
  onConfirmAndSave,
}: {
  employee: Employee;
  state: RowSaveState;
  field: 'email' | 'phone';
  hidePrimaryFieldError?: boolean;
  canEdit: boolean;
  onToggleSamePerson: (checked: boolean) => void;
  onConfirmAndSave: () => void;
}) {
  const fieldErrors = state.fieldErrors[field] ?? [];
  const fieldWarnings = state.warnings.filter((warning) => warning.field === field);

  return (
    <div className="space-y-1.5">
      {!hidePrimaryFieldError && !state.samePersonRequired && fieldErrors.map((msg) => (
        <p key={msg} role="alert" className="mt-1 flex items-start gap-1 text-xs text-danger-700">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
          <span>{msg}</span>
        </p>
      ))}

      {field === 'email' && state.samePersonRequired && (
        <div role="alert" className="mt-2 rounded-lg border border-warning-300 bg-warning-50 p-2.5 text-xs text-warning-950">
          <p className="flex items-start gap-1.5 font-medium">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
            <span>{fieldErrors[0] || `This email belongs to an existing payroll login for ${employee.first_name} ${employee.last_name}.`}</span>
          </p>
          <label className="mt-2 flex cursor-pointer items-start gap-2">
            <input
              type="checkbox"
              checked={state.samePersonChecked}
              disabled={!canEdit || state.saving}
              onChange={(event) => onToggleSamePerson(event.target.checked)}
              className="mt-0.5 h-4 w-4 rounded border-warning-400 text-primary-700 focus:ring-primary-500"
            />
            <span className="font-medium text-neutral-900">
              Confirm this login belongs to {employee.first_name} {employee.last_name} (audited)
            </span>
          </label>
          <div className="mt-2">
            <Button
              size="sm"
              disabled={!canEdit || !state.samePersonChecked || state.saving}
              loading={state.saving}
              loadingLabel="Saving..."
              onClick={onConfirmAndSave}
            >
              Confirm & save
            </Button>
          </div>
        </div>
      )}

      {fieldWarnings.map((warning) => (
        <p key={`${warning.code}-${warning.message}`} role="status" className="mt-1 flex items-start gap-1.5 rounded-lg border border-warning-200 bg-warning-50 px-2 py-1.5 text-xs text-warning-900">
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning-700" aria-hidden="true" />
          <span>{warning.message}</span>
        </p>
      ))}
    </div>
  );
}
