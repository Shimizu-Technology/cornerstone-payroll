import {
  Fragment,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type Dispatch,
  type KeyboardEvent,
  type ReactElement,
  type ReactNode,
  type SetStateAction,
} from 'react';
import { Link, useSearchParams } from 'react-router';
import {
  AlertTriangle,
  ArrowLeft,
  CheckCircle2,
  Pencil,
  ChevronLeft,
  ChevronRight,
  Search,
} from 'lucide-react';
import {
  AddressValue,
  ContactEditor,
  ContactSaveResult,
  ContactValue,
  SharedEmailNote,
} from '@/components/employees/ContactEditor';
import {
  CONTACT_FIELDS,
  INITIAL_ROW_STATE,
  baselineFromEmployee,
  contactStatusBadge,
  editRowDraft,
  effectiveDraft,
  extractConflictPayload,
  extractContactValidation,
  hasAddressChanges,
  hasAnyChangedField,
  rowSaveRequest,
  type ContactDraftMap,
  type ContactDraftPatch,
  type ContactField,
  type RowFieldDrafts,
  type RowSaveState,
} from '@/lib/employee-contact-editor';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { MobileRecordCard } from '@/components/ui/mobile-record';
import { Select } from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Alert } from '@/components/ui/alert';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteClientEmployeeProfile, canWriteCompany, companyReadOnlyMessage } from '@/lib/company-write-access';
import { formatPhone } from '@/lib/display-phone';
import { toContactRecord } from '@/lib/employee-contact';
import { employeesPath } from '@/lib/routes';
import { cn, getInitials } from '@/lib/utils';
import { clientEmployeesApi, employeesApi } from '@/services/api';
import type { ContactEmployee, PaginationMeta } from '@/types';

export type { ContactDraftMap, ContactFieldDraft, RowFieldDrafts, RowSaveState } from '@/lib/employee-contact-editor';

const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
const PER_PAGE = 50;



export interface EmployeeContactDetailsProps {
  /** Optional wrapper chrome (e.g. staff-only tabs) rendered above the grid. */
  topSlot?: ReactNode;
  /** Incrementing this triggers a reload of the current page while preserving pending edits. */
  refreshKey?: number;
  /** Callback notified when needs_contact_details_count updates. */
  onNeedsContactCountChange?: (count: number) => void;
  /** When true, omit the outer Header wrapper because a parent page renders it. */
  embedded?: boolean;
  /** Optional controlled per-field draft map lifted above tab switches. */
  drafts?: ContactDraftMap;
  onDraftsChange?: Dispatch<SetStateAction<ContactDraftMap>>;
  /** Optional controlled row feedback state lifted above tab switches. */
  rowStates?: Record<number, RowSaveState>;
  onRowStatesChange?: Dispatch<SetStateAction<Record<number, RowSaveState>>>;
}

export function EmployeeContactDetails({
  topSlot,
  refreshKey = 0,
  onNeedsContactCountChange,
  embedded = false,
  drafts: controlledDrafts,
  onDraftsChange,
  rowStates: controlledRowStates,
  onRowStatesChange,
}: EmployeeContactDetailsProps = {}): ReactElement {
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

  const [employees, setEmployees] = useState<ContactEmployee[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [loadedCompanyId, setLoadedCompanyId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  // Sparse per-field pending edits keyed by employee ID, storing each field's
  // original baseline value and row revision from when editing started.
  const [internalDrafts, setInternalDrafts] = useState<ContactDraftMap>({});
  const [internalRowStates, setInternalRowStates] = useState<Record<number, RowSaveState>>({});
  const drafts = controlledDrafts ?? internalDrafts;
  const setDrafts = onDraftsChange ?? setInternalDrafts;
  const rowStates = controlledRowStates ?? internalRowStates;
  const setRowStates = onRowStatesChange ?? setInternalRowStates;
  const isDraftsControlled = controlledDrafts !== undefined;
  const isDesktop = useDesktopLayout();
  // Rows opened with Edit. A row also stays open while it has unsaved edits
  // or something to resolve, so drafts kept across pages and tabs reopen.
  const [editingIds, setEditingIds] = useState<Set<number>>(() => new Set());
  const requestIdRef = useRef(0);
  const companyIdRef = useRef(companyId);
  const prevCompanyIdRef = useRef(companyId);
  const searchParamsRef = useRef(searchParams);
  searchParamsRef.current = searchParams;

  useLayoutEffect(() => {
    companyIdRef.current = companyId;
    setIsLoading(true);
    setLoadError(null);
    if (prevCompanyIdRef.current !== companyId) {
      prevCompanyIdRef.current = companyId;
      if (!isDraftsControlled) {
        setInternalDrafts({});
        setInternalRowStates({});
      }
    }
  }, [companyId, isDraftsControlled]);

  const fetchEmployees = useCallback(async (): Promise<void> => {
    const requestedCompanyId = companyId;
    if (requestedCompanyId !== companyIdRef.current) return;
    const requestId = ++requestIdRef.current;
    let clampedPage = false;

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
        view: 'contact' as const,
      };
      const payload = isClient
        ? await clientEmployeesApi.list(listParams)
        : await employeesApi.list({ company_id: requestedCompanyId, ...listParams });

      if (requestId !== requestIdRef.current || requestedCompanyId !== companyIdRef.current) return;

      const serverTotalCount = payload.meta.total_count;
      const serverPerPage = payload.meta.per_page || PER_PAGE;
      const lastPage = serverTotalCount > 0
        ? Math.max(1, payload.meta.total_pages || Math.ceil(serverTotalCount / serverPerPage))
        : 1;

      if (page > lastPage) {
        clampedPage = true;
        const next = new URLSearchParams(searchParamsRef.current);
        if (lastPage <= 1) next.delete('page');
        else next.set('page', String(lastPage));
        setSearchParams(next, { replace: true });
        return;
      }

      // Refresh server data (updating untouched fields) without touching any
      // edited field's captured baseline value or row revision.
      setEmployees(payload.data.map(toContactRecord));
      setMeta(payload.meta);
      setLoadedCompanyId(requestedCompanyId);
    } catch (caught) {
      if (requestId !== requestIdRef.current || requestedCompanyId !== companyIdRef.current) return;
      setLoadError(caught instanceof Error ? caught.message : 'Could not load employee contact details.');
    } finally {
      if (!clampedPage && requestId === requestIdRef.current && requestedCompanyId === companyIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [companyId, isClient, needsContactOnly, page, search, setSearchParams, statusFilter]);

  useEffect(() => {
    void fetchEmployees();
  }, [fetchEmployees, refreshKey]);

  const updateFilter = (key: string, value: string, replace = false): void => {
    const next = new URLSearchParams(searchParams);
    if (value) next.set(key, value);
    else next.delete(key);
    if (key !== 'page') next.delete('page');
    setSearchParams(next, { replace });
  };

  const setPage = (nextPage: number): void => {
    const clamped = Math.max(1, Math.min(nextPage, meta?.total_pages || nextPage));
    updateFilter('page', clamped <= 1 ? '' : String(clamped));
  };

  const companyEmployees = useMemo(
    () => (loadedCompanyId === companyId ? employees : []),
    [companyId, employees, loadedCompanyId],
  );

  const dirtyCount = useMemo(() => {
    let count = 0;
    for (const rowDraft of Object.values(drafts)) {
      if (hasAnyChangedField(rowDraft)) count += 1;
    }
    return count;
  }, [drafts]);

  const needsContactCount = meta?.needs_contact_details_count
    ?? companyEmployees.filter((emp) => emp.contact_details_status?.needs_contact_details).length;

  useEffect(() => {
    onNeedsContactCountChange?.(needsContactCount);
  }, [needsContactCount, onNeedsContactCountChange]);

  const updateDraftField = (employee: ContactEmployee, field: ContactField, value: string): void => {
    setDrafts((prev) => {
      const row = editRowDraft(prev[employee.id], employee, field, value);
      if (row === prev[employee.id]) return prev;
      const next = { ...prev };
      if (row) next[employee.id] = row;
      else delete next[employee.id];
      return next;
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
          confirmingAddressReplacement: false,
          fieldErrors: { ...current.fieldErrors, [field]: [] },
          ...(field === 'email' ? { samePersonRequired: false, samePersonChecked: false } : {}),
        },
      };
    });
  };

  const isRowOpen = (employee: ContactEmployee): boolean => {
    const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
    return editingIds.has(employee.id)
      || hasAnyChangedField(drafts[employee.id])
      || Boolean(state.conflict || state.samePersonRequired || state.error)
      || Object.values(state.fieldErrors).some((messages) => messages.length > 0);
  };

  const setRowEditing = (employeeId: number, editing: boolean): void => {
    setEditingIds((prev) => {
      if (prev.has(employeeId) === editing) return prev;
      const next = new Set(prev);
      if (editing) next.add(employeeId);
      else next.delete(employeeId);
      return next;
    });
  };

  const openRow = (employee: ContactEmployee): void => {
    setRowEditing(employee.id, true);
    setRowStates((prev) => (prev[employee.id]?.saved ? { ...prev, [employee.id]: { ...prev[employee.id], saved: false } } : prev));
  };

  const cancelRow = (employee: ContactEmployee): void => {
    resetRow(employee);
    setRowEditing(employee.id, false);
  };

  const resetRow = (employee: ContactEmployee): void => {
    setDrafts((prev) => {
      if (!prev[employee.id]) return prev;
      const next = { ...prev };
      delete next[employee.id];
      return next;
    });
    setRowStates((prev) => ({ ...prev, [employee.id]: INITIAL_ROW_STATE }));
  };

  const toggleSamePersonCheck = (employeeId: number, checked: boolean): void => {
    setRowStates((prev) => ({
      ...prev,
      [employeeId]: {
        ...(prev[employeeId] ?? INITIAL_ROW_STATE),
        samePersonChecked: checked,
      },
    }));
  };

  const saveRow = async (
    employee: ContactEmployee,
    options: {
      explicitConfirmSamePerson?: boolean;
      confirmReplaceAddress?: boolean;
      overrideBaselineEmployee?: ContactEmployee;
      overrideChanges?: ContactDraftPatch;
    } = {},
  ): Promise<void> => {
    if (!canEdit) return;
    const baseEmployee = options.overrideBaselineEmployee ?? employee;
    const currentState = rowStates[employee.id] ?? INITIAL_ROW_STATE;
    const confirmSamePerson = Boolean(
      options.explicitConfirmSamePerson || (currentState.samePersonRequired && currentState.samePersonChecked),
    );

    const changes: ContactDraftPatch = {};
    const baselineValues: Record<string, string> = {};
    let rowRevision = baseEmployee.contact_revision || baseEmployee.updated_at;

    if (options.overrideChanges) {
      const serverBaseline = baselineFromEmployee(baseEmployee);
      for (const field of CONTACT_FIELDS) {
        if (options.overrideChanges[field] !== undefined) {
          changes[field] = options.overrideChanges[field];
          baselineValues[field] = serverBaseline[field];
        }
      }
    } else {
      const request = rowSaveRequest(drafts[employee.id], employee);
      Object.assign(changes, request.changes);
      Object.assign(baselineValues, request.baselineValues);
      rowRevision = request.rowRevision;
    }

    const changedKeys = Object.keys(changes) as ContactField[];
    if (changedKeys.length === 0 && !confirmSamePerson) return;

    if (
      !isClient
      && baseEmployee.contact_details_status?.has_pending_address_request
      && hasAddressChanges(changes)
      && !options.confirmReplaceAddress
    ) {
      setRowStates((prev) => ({
        ...prev,
        [employee.id]: {
          ...(prev[employee.id] ?? INITIAL_ROW_STATE),
          confirmingAddressReplacement: true,
          error: null,
        },
      }));
      return;
    }

    setRowStates((prev) => ({
      ...prev,
      [employee.id]: {
        ...(prev[employee.id] ?? INITIAL_ROW_STATE),
        saving: true,
        saved: false,
        submittedAddressRequestId: undefined,
        pendingAddressRequestId: undefined,
        confirmingAddressReplacement: false,
        error: null,
        fieldErrors: {},
        conflict: null,
      },
    }));

    const payload = {
      ...changes,
      row_revision: rowRevision,
      ...(changedKeys.length > 0 ? { baseline_values: baselineValues } : {}),
      ...(confirmSamePerson ? { confirm_same_person_email: true } : {}),
    };

    try {
      const contactPayload = { ...payload, response_view: 'contact' as const };
      const response = isClient
        ? await clientEmployeesApi.update(employee.id, contactPayload)
        : await employeesApi.update(employee.id, contactPayload, companyId);

      const updated = toContactRecord(response.data);
      const warnings = response.contact_warnings ?? [];
      const addressRequest = 'change_request' in response && response.change_request?.profile_address ? response.change_request : null;

      setEmployees((prev) => prev.map((item) => (item.id === updated.id ? { ...item, ...updated } : item)));
      setDrafts((prev) => {
        if (!prev[updated.id]) return prev;
        const next = { ...prev };
        delete next[updated.id];
        return next;
      });
      setRowEditing(updated.id, false);
      setRowStates((prev) => ({
        ...prev,
        [updated.id]: {
          saving: false,
          saved: true,
          submittedAddressRequestId: addressRequest?.id,
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
          pendingAddressRequestId: parsed.pendingAddressRequestId,
          fieldErrors: parsed.fieldErrors,
          warnings: parsed.warnings,
          samePersonRequired: parsed.samePersonRequired,
          samePersonChecked: parsed.samePersonRequired ? Boolean(prev[employee.id]?.samePersonChecked) : false,
          conflict: null,
        },
      }));
    }
  };

  const handleKeepMyVersion = (employee: ContactEmployee): void => {
    const conflict = rowStates[employee.id]?.conflict;
    if (!conflict) return;
    // User explicitly chose to keep their version: rebase each edited field's
    // baseline onto the latest server record, refresh untouched fields, and re-submit.
    const serverBaseline = baselineFromEmployee(conflict.serverEmployee);
    const serverRevision = conflict.serverEmployee.contact_revision || conflict.serverEmployee.updated_at;
    setEmployees((prev) => prev.map((item) => (item.id === employee.id ? { ...item, ...conflict.serverEmployee } : item)));
    setDrafts((prev) => {
      const existingRow = prev[employee.id];
      if (!existingRow) return prev;
      const rebasedRow: RowFieldDrafts = {};
      for (const field of CONTACT_FIELDS) {
        const entry = existingRow[field];
        if (!entry) continue;
        if (conflict.userChanges[field] === undefined) {
          // A formatting-only phone draft was never sent in the conflicting save.
          rebasedRow[field] = entry;
          continue;
        }
        rebasedRow[field] = {
          value: entry.value,
          baselineValue: serverBaseline[field],
          baselineRevision: serverRevision,
        };
      }
      return { ...prev, [employee.id]: rebasedRow };
    });
    void saveRow(employee, {
      overrideBaselineEmployee: conflict.serverEmployee,
      overrideChanges: conflict.userChanges,
      confirmReplaceAddress: true,
    });
  };

  // "Use theirs" drops only the drafts that conflicted. Other edits on the row,
  // such as a phone typed alongside a conflicting email, stay ready to save
  // with their original baselines.
  const handleDiscardMyVersion = (employee: ContactEmployee): void => {
    const conflict = rowStates[employee.id]?.conflict;
    if (!conflict) return;
    const named = conflict.conflictingFields.filter((field): field is ContactField => CONTACT_FIELDS.includes(field as ContactField));
    const dropped = new Set<ContactField>(named.length > 0 ? named : (Object.keys(conflict.userChanges) as ContactField[]));
    setEmployees((prev) => prev.map((item) => (item.id === employee.id ? { ...item, ...conflict.serverEmployee } : item)));
    setDrafts((prev) => {
      const existingRow = prev[employee.id];
      if (!existingRow) return prev;
      const keptRow: RowFieldDrafts = {};
      for (const field of CONTACT_FIELDS) {
        const entry = existingRow[field];
        if (entry && !dropped.has(field)) keptRow[field] = entry;
      }
      const next = { ...prev };
      if (Object.keys(keptRow).length > 0) next[employee.id] = keptRow;
      else delete next[employee.id];
      return next;
    });
    setRowStates((prev) => ({ ...prev, [employee.id]: INITIAL_ROW_STATE }));
  };

  const handleRowKeyDown = (event: KeyboardEvent<HTMLInputElement>, employee: ContactEmployee): void => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
      if (!state.saving && !state.confirmingAddressReplacement && (hasAnyChangedField(drafts[employee.id]) || (state.samePersonRequired && state.samePersonChecked))) {
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

  const renderEditor = (employee: ContactEmployee): ReactElement => {
    const draft = effectiveDraft(employee, drafts[employee.id]);
    return (
      <ContactEditor
        className="lg:rounded-xl lg:border lg:border-primary-200 lg:p-4"
        employee={employee}
        draft={draft}
        phoneValue={drafts[employee.id]?.phone ? draft.phone : formatPhone(draft.phone)}
        state={rowStates[employee.id] ?? INITIAL_ROW_STATE}
        canEdit={canEdit}
        dirty={hasAnyChangedField(drafts[employee.id])}
        onFieldChange={(field, value) => updateDraftField(employee, field, value)}
        onKeyDown={(event) => handleRowKeyDown(event, employee)}
        onToggleSamePerson={(checked) => toggleSamePersonCheck(employee.id, checked)}
        onConfirmSamePerson={() => void saveRow(employee, { explicitConfirmSamePerson: true })}
        onConfirmAddressReplacement={() => void saveRow(employee, { confirmReplaceAddress: true })}
        onCancelAddressReplacement={() => setRowStates((prev) => ({
          ...prev,
          [employee.id]: { ...(prev[employee.id] ?? INITIAL_ROW_STATE), confirmingAddressReplacement: false },
        }))}
        onKeepMine={() => handleKeepMyVersion(employee)}
        onUseTheirs={() => handleDiscardMyVersion(employee)}
        onCancel={() => cancelRow(employee)}
        onSave={() => void saveRow(employee)}
      />
    );
  };

  const gridBody = (
    <>
      {topSlot}

      {!canEdit && (
        <Alert tone="info">{companyReadOnlyMessage(activeCompany)}</Alert>
      )}

      {/* Summary strip + filter bar */}
      <div className="flex flex-col gap-4 rounded-xl border border-neutral-200 bg-white p-4">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              aria-pressed={needsContactOnly}
              onClick={() => updateFilter('needs_contact_details', needsContactOnly ? '' : 'true')}
              className={cn(
                'inline-flex min-h-11 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition sm:min-h-10 sm:pointer-coarse:min-h-11',
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

          <div className="flex flex-wrap items-center gap-4 text-xs text-neutral-600">
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

        <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
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

        </div>
      </div>

      {loadError && (
        <Alert tone="error" className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
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
          <h2 className="mt-4 text-base font-semibold text-neutral-900">
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
          {isDesktop ? (
            <Card className="relative z-0 overflow-hidden">
              <Table stickyHeader>
                <TableHeader>
                  <TableRow>
                    <TableHead stickyLeft className="z-[2] w-[200px] px-4">Employee</TableHead>
                    <TableHead className="px-4">Email</TableHead>
                    <TableHead className="w-[168px] px-4">Mobile</TableHead>
                    <TableHead className="px-4">Mailing address</TableHead>
                    <TableHead className="w-[112px] px-4 text-right"><span className="sr-only">Edit</span></TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {companyEmployees.map((employee, index) => {
                    const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
                    const open = isRowOpen(employee);
                    const rowBg = index % 2 === 0 ? 'bg-white' : 'bg-neutral-50/70';
                    const name = `${employee.first_name} ${employee.last_name}`;

                    return (
                      <Fragment key={employee.id}>
                        <TableRow className={cn(rowBg, 'align-top')}>
                          <TableCell stickyLeft className={cn(rowBg, 'z-[1] whitespace-normal px-4 py-4')}>
                            <EmployeeNameBlock employee={employee} />
                          </TableCell>
                          <TableCell className="whitespace-normal px-4 py-4 text-sm">
                            <ContactValue value={employee.email} className="break-all" />
                            {!open && <SharedEmailNote employee={employee} warnings={state.warnings} />}
                          </TableCell>
                          <TableCell className="whitespace-nowrap px-4 py-4 text-sm tabular-nums">
                            <ContactValue value={formatPhone(employee.phone)} />
                            {employee.phone_confirmed_by_employee_at && (
                              <p className="mt-1 text-xs font-medium text-success-700">Confirmed by employee</p>
                            )}
                          </TableCell>
                          <TableCell className="whitespace-normal px-4 py-4 text-sm">
                            <AddressValue employee={employee} />
                          </TableCell>
                          <TableCell className="px-4 py-4 text-right">
                            {open ? (
                              <span className="text-xs font-semibold text-primary-700">Editing</span>
                            ) : (
                              <div className="flex flex-col items-end gap-2">
                                <Button variant="outline" size="sm" aria-label={`Edit ${name}`} disabled={!canEdit} onClick={() => openRow(employee)}>
                                  <Pencil className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
                                  Edit
                                </Button>
                                {state.saved && (
                                  <span role="status" className="inline-flex items-center gap-1 text-xs font-semibold text-success-700">
                                    <ContactSaveResult requestId={state.submittedAddressRequestId} />
                                  </span>
                                )}
                              </div>
                            )}
                          </TableCell>
                        </TableRow>
                        {open && (
                          <TableRow className={rowBg}>
                            <TableCell colSpan={5} className="whitespace-normal border-t-0 px-4 pb-4 pt-0">
                              {renderEditor(employee)}
                            </TableCell>
                          </TableRow>
                        )}
                      </Fragment>
                    );
                  })}
                </TableBody>
              </Table>
            </Card>
          ) : (
            <div className="space-y-4">
              {companyEmployees.map((employee) => {
                const state = rowStates[employee.id] ?? INITIAL_ROW_STATE;
                const open = isRowOpen(employee);
                const name = `${employee.first_name} ${employee.last_name}`;

                return (
                  <MobileRecordCard key={employee.id}>
                    <div className="flex items-start justify-between gap-4">
                      <EmployeeNameBlock employee={employee} />
                      {state.saved && !open && (
                        <span role="status" className="inline-flex shrink-0 items-center gap-1 text-xs font-semibold text-success-700">
                          <ContactSaveResult requestId={state.submittedAddressRequestId} />
                        </span>
                      )}
                    </div>
                    {open ? (
                      <div className="mt-4">{renderEditor(employee)}</div>
                    ) : (
                      <button
                        type="button"
                        aria-label={`Edit ${name}`}
                        disabled={!canEdit}
                        onClick={() => openRow(employee)}
                        className="mt-4 block w-full rounded-lg text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 disabled:cursor-default"
                      >
                        <dl className="space-y-2 text-sm">
                          <div>
                            <dt className="text-xs font-medium text-neutral-500">Email</dt>
                            <dd>
                              <ContactValue value={employee.email} className="break-all" />
                              <SharedEmailNote employee={employee} warnings={state.warnings} />
                            </dd>
                          </div>
                          <div>
                            <dt className="text-xs font-medium text-neutral-500">Mobile</dt>
                            <dd className="tabular-nums"><ContactValue value={formatPhone(employee.phone)} /></dd>
                          </div>
                          <div>
                            <dt className="text-xs font-medium text-neutral-500">Mailing address</dt>
                            <dd><AddressValue employee={employee} /></dd>
                          </div>
                        </dl>
                        {canEdit && (
                          <span className="mt-4 inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-full border border-neutral-300 text-sm font-semibold text-neutral-800">
                            <Pencil className="h-4 w-4" aria-hidden="true" />
                            Edit contact details
                          </span>
                        )}
                      </button>
                    )}
                  </MobileRecordCard>
                );
              })}
            </div>
          )}
        </>
      )}

      {!isLoading && (totalPages > 1 || (currentPage > 1 && totalCount > 0)) && (
        <nav
          aria-label="Contact details pagination"
          className="flex flex-col items-center justify-between gap-4 rounded-xl border border-neutral-200 bg-white px-4 py-4 sm:flex-row"
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
  );

  if (embedded) {
    return gridBody;
  }

  return (
    <div>
      <Header
        title="Contact details"
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

      <div className="space-y-8 p-4 sm:p-6 lg:p-8">
        {gridBody}
      </div>
    </div>
  );
}

const DESKTOP_QUERY = '(min-width: 1024px)';

// One layout at a time, so each field exists once on the page.
function useDesktopLayout(): boolean {
  const query = (): MediaQueryList | null => (typeof window.matchMedia === 'function' ? window.matchMedia(DESKTOP_QUERY) : null);
  const [desktop, setDesktop] = useState(() => query()?.matches ?? true);
  useEffect(() => {
    const list = query();
    if (!list) return undefined;
    const update = (): void => setDesktop(list.matches);
    list.addEventListener('change', update);
    return () => list.removeEventListener('change', update);
  }, []);
  return desktop;
}


function EmployeeNameBlock({ employee }: { employee: ContactEmployee }): ReactElement {
  const badge = contactStatusBadge(employee);
  return (
    <div className="flex min-w-0 items-start gap-2">
      <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary-100 text-xs font-semibold text-primary-700">
        {getInitials(employee.first_name, employee.last_name)}
      </div>
      <div className="min-w-0 space-y-1">
        <p className="text-sm font-semibold leading-snug text-neutral-950">
          {employee.first_name} {employee.last_name}
        </p>
        <div className="flex flex-wrap gap-1">
          <Badge variant={badge.variant}>{badge.label}</Badge>
          {employee.email_verified_at && <Badge variant="success">Email confirmed</Badge>}
        </div>
      </div>
    </div>
  );
}

