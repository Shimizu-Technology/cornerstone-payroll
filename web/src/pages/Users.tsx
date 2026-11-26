import { formatGuamDateTime } from '@/lib/utils';
import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { roleLabel } from '@/lib/role-labels';
import { invitationOutcomeMessage } from '@/lib/invitationOutcome';
import { useState, useEffect, useCallback, useId, useRef, Fragment, type Dispatch, type SetStateAction } from 'react';
import { Plus, Check, X, AlertCircle, UserCheck, UserX, Mail, RefreshCw, Trash2, UserCircle, Activity, ShieldCheck, ArrowRightLeft, FlaskConical, ChevronDown } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { usersApi, companiesApi, ApiError } from '@/services/api';
import type { ClientAccessLevel, User, UserRole } from '@/types';
import type { CompanyListItem, InvitationDeliveryResponse } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import { ClientManagementDialog } from '@/components/users/ClientManagementDialog';
import { UserActivityPanel } from '@/components/users/UserActivityPanel';
import { RecoverClerkLoginDialog } from '@/components/users/RecoverClerkLoginDialog';
import { MovePracticeLoginDialog } from '@/components/users/MovePracticeLoginDialog';
import { RoleGuide, RoleHint, type RoleOption } from '@/components/users/RoleGuide';
import {
  assignmentCompanyIdsForRole,
  groupAssignmentCompanies,
  isPreparingPracticeCopy,
  isTestWorkspaceCompany,
  needsClientAssignment,
  toggleAssignment,
  type AssignmentOption,
} from '@/lib/user-company-access';

const allRoleOptions: RoleOption[] = [
  { value: 'super_admin', label: 'Super Admin', scope: 'Every organization and client', can: 'Manage platform organizations, recover access, and perform every organization-admin action.', cannot: 'This is an exceptional platform role and should not be used for normal payroll work.', assignment: 'No client assignment required.', exceptional: true },
  { value: 'org_admin', label: 'Organization Admin', scope: 'Every client in their organization', can: 'Manage users, clients, tax configuration, audit history, client check controls, and payroll operations.', cannot: 'Cannot manage other organizations or platform-wide settings.', assignment: 'Automatically receives all organization clients.' },
  { value: 'admin', label: 'Organization Admin (legacy)', scope: 'Every client in their organization', can: 'Same access as Organization Admin.', cannot: 'Legacy role name retained for existing accounts; use Organization Admin for new invitations.', assignment: 'Automatically receives all organization clients.', legacy: true },
  { value: 'manager', label: 'Manager', scope: 'Only assigned payroll clients', can: 'Run payroll, manage employees, configure client settings, and manage the shared printer-profile library.', cannot: 'Cannot manage users, organization tax configuration, or organization-wide audit history.', assignment: 'At least one payroll client should be assigned.' },
  { value: 'accountant', label: 'Accountant', scope: 'Only assigned payroll clients', can: 'Run payroll, manage employees and payroll fields, view assigned-client history, and create, select, or copy printer profiles.', cannot: 'Client management is off by default. An administrator can grant it separately for each assigned client. This never grants Users, source credentials, firm-wide settings, or another person’s printer-profile access.', assignment: 'At least one payroll client should be assigned.' },
  { value: 'client', label: 'Client Portal User', scope: 'Only assigned client portal workspaces', can: 'As a Client manager: maintain employee records, upload documents, review payroll and reports, and submit approvals or change requests. A Client viewer can only view.', cannot: 'Cannot enter the internal payroll workspace, print checks, or see firm-wide settings and audit history.', assignment: 'Assign only the client companies this person represents.' },
  { value: 'employee', label: 'Employee', scope: 'No payroll workspace access today', can: 'Reserved for a future employee self-service experience.', cannot: 'Cannot currently sign in to staff or client payroll workspaces.', assignment: 'Do not use for active access until the employee portal is released.' },
];

// A failed or unknown delivery means the person was created but cannot sign in yet.
function invitationNeedsRetry(response: InvitationDeliveryResponse): boolean {
  return response.invitation_delivery_status === 'failed'
    || !['captured', 'queued', 'submitted', 'not_requested'].includes(response.invitation_delivery_status);
}

function errorCode(err: unknown): string | undefined {
  if (!(err instanceof ApiError) || !err.data || typeof err.data !== 'object') return undefined;
  const code = (err.data as { code?: unknown }).code;
  return typeof code === 'string' ? code : undefined;
}

const sameIds = (left: number[], right: number[]) =>
  left.length === right.length && left.every((id, index) => id === right[index]);

function inviteFailureReason(response: InvitationDeliveryResponse): string {
  if (response.invitation_delivery_status === 'failed') {
    return `Invitation email failed${response.invitation_error ? `: ${response.invitation_error}` : ''}.`;
  }
  return invitationOutcomeMessage(response);
}

// The account list keeps the editor's "(legacy)" marker for older admin accounts.
function accountRoleLabel(role: UserRole): string {
  return allRoleOptions.find((option) => option.value === role)?.label ?? roleLabel(role);
}

const clientAccessOptions: { value: ClientAccessLevel; label: string; hint: string }[] = [
  { value: 'manager', label: 'Client manager', hint: 'Full client portal access: approve payroll, edit employees, upload documents, send messages and invite employees.' },
  { value: 'viewer', label: 'Client viewer', hint: 'View only: sees payroll, employees, reports, documents and messages, and can’t change anything.' },
];

function clientAccessLabel(level: ClientAccessLevel | null | undefined): string {
  return clientAccessOptions.find((option) => option.value === (level ?? 'manager'))?.label ?? 'Client manager';
}

function userRoleLabel(user: User): string {
  return user.role === 'client' ? `${accountRoleLabel(user.role)} · ${clientAccessLabel(user.client_access_level)}` : accountRoleLabel(user.role);
}

function ClientAccessField({ value, onChange, disabled }: { value: ClientAccessLevel; onChange: (level: ClientAccessLevel) => void; disabled?: boolean }) {
  return (
    <div className="space-y-1">
      <Select label="Client access" value={value} disabled={disabled} onChange={(event) => onChange(event.target.value as ClientAccessLevel)}>
        {clientAccessOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
      </Select>
      <p className="text-xs text-neutral-600">{clientAccessOptions.find((option) => option.value === value)?.hint}</p>
    </div>
  );
}

type InviteFieldErrors = { email?: string; clients?: string };
const CLIENT_REQUIRED_MESSAGE = 'Choose at least one client for a client portal user.';

function inviteFieldErrors(email: string, role: UserRole, companyIds: number[]): InviteFieldErrors {
  const errors: InviteFieldErrors = {};
  const trimmed = email.trim();
  if (!trimmed) errors.email = 'Enter the email address to send the invitation to.';
  else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed)) errors.email = 'Enter a full email address, like name@example.com.';
  if (role === 'client' && companyIds.length === 0) errors.clients = CLIENT_REQUIRED_MESSAGE;
  return errors;
}

// Server refusals that name one field go under that field.
function inviteServerFieldErrors(err: ApiError): InviteFieldErrors {
  if (errorCode(err) === 'client_required') return { clients: CLIENT_REQUIRED_MESSAGE };
  const raw = err.data && typeof err.data === 'object' ? (err.data as { error?: unknown }).error : undefined;
  const messages = (Array.isArray(raw) ? raw : [raw]).filter((value): value is string => typeof value === 'string');
  if (messages.length === 0 || !messages.every((message) => /^Email\b/.test(message))) return {};
  if (messages.some((message) => /already been taken/i.test(message))) {
    return { email: 'This email already has an account. Find it in the list below.' };
  }
  return { email: messages.join(' ') };
}

export function Users() {
  const { user: currentUser } = useAuth();
  const inviteEmailId = useId();
  const inviteClientsId = useId();
  const roleOptions = currentUser?.role === 'super_admin'
    ? allRoleOptions
    : allRoleOptions.filter((role) => role.value !== 'super_admin');
  const invitationRoleOptions = roleOptions.filter((role) => !role.legacy && role.value !== 'employee');
  const roleGuideOptions = roleOptions.filter((role) => !role.legacy);

  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setErrorMessage, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  // Next steps offered beside a refused action, such as Move for a login whose practice copy closed.
  const [errorActions, setErrorActions] = useState<{ user: User; deactivate?: boolean; move?: boolean } | null>(null);
  const setError = useCallback((message: string | null, actions: { user: User; deactivate?: boolean; move?: boolean } | null = null) => {
    setErrorMessage(message);
    setErrorActions(actions);
  }, [setErrorMessage]);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  // The account exists but the sign-in invitation did not go out. Kept apart from
  // success so it reads as unfinished work, with a retry beside it.
  const [inviteWarning, setInviteWarning] = useState<{ user: User; reason: string; confirmedFailure: boolean } | null>(null);

  // New user form
  const [isAddingNew, setIsAddingNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [newRole, setNewRole] = useState<UserRole>('accountant');
  const [newClientAccess, setNewClientAccess] = useState<ClientAccessLevel>('manager');
  const [newError, setNewError, newErrorFeedbackAttempt] = useFeedbackState<string | null>(null);
  // Errors that belong to one field are shown under that field, not as a notice.
  const [newFieldErrors, setNewFieldErrors] = useState<InviteFieldErrors>({});
  const [isSavingNew, setIsSavingNew] = useState(false);
  const [newClientIds, setNewClientIds] = useState<number[]>([]);
  const [availableCompanies, setAvailableCompanies] = useState<CompanyListItem[]>([]);
  const [isLoadingCompanies, setIsLoadingCompanies] = useState(false);
  const [companiesLoadError, setCompaniesLoadError] = useState<string | null>(null);
  const [companiesLoadCount, setCompaniesLoadCount] = useState(0);
  const companiesRequestIdRef = useRef(0);

  // Edit user
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editRole, setEditRole] = useState<UserRole>('employee');
  const [editClientAccess, setEditClientAccess] = useState<ClientAccessLevel>('manager');
  const [editClientIds, setEditClientIds] = useState<number[]>([]);
  const [editError, setEditError, editErrorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);
  const editRoleOptions = roleOptions.filter((role) =>
    (!role.legacy && role.value !== 'employee') || editRole === role.value);

  const [resendingId, setResendingId] = useState<number | null>(null);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [togglingId, setTogglingId] = useState<number | null>(null);
  const [managementUser, setManagementUser] = useState<User | null>(null);
  const [recoveryUser, setRecoveryUser] = useState<User | null>(null);
  const recoveryAction = (user: User) => user.can_recover_clerk_invitation
    ? <Button size="sm" variant="outline" onClick={() => setRecoveryUser(user)}>Recover login</Button> : null;
  const [moveUser, setMoveUser] = useState<User | null>(null);
  const canDelegate = ['admin', 'org_admin', 'super_admin'].includes(currentUser?.role ?? '');
  const managementAction = (user: User) => canDelegate && user.role === 'accountant' && user.id !== currentUser?.id
    ? <Button size="sm" variant="outline" onClick={() => setManagementUser(user)}>Client management</Button> : null;
  const [activityUser, setActivityUser] = useState<User | null>(null);
  const handleCloseActivity = useCallback(() => setActivityUser(null), []);

  // keepFeedback refreshes the list without touching a result the caller just
  // showed; a failure is returned so the caller can add it to that result.
  const fetchUsers = useCallback(async ({ keepFeedback = false }: { keepFeedback?: boolean } = {}): Promise<string | null> => {
    setIsLoading(true);
    if (!keepFeedback) setError(null);
    try {
      const response = await usersApi.list();
      setUsers(response.data);
      return null;
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load users';
      if (!keepFeedback) setError(message);
      return message;
    } finally {
      setIsLoading(false);
    }
  }, [setError]);

  const loadCompanies = useCallback(async () => {
    const requestId = companiesRequestIdRef.current + 1;
    companiesRequestIdRef.current = requestId;
    setIsLoadingCompanies(true);
    setCompaniesLoadError(null);
    let shouldUpdate = true;
    try {
      const res = await companiesApi.list();
      if (requestId !== companiesRequestIdRef.current) {
        shouldUpdate = false;
        return;
      }
      setAvailableCompanies(res.companies);
    } catch (err) {
      if (requestId !== companiesRequestIdRef.current) {
        shouldUpdate = false;
        return;
      }
      setCompaniesLoadError(err instanceof Error ? err.message : 'Failed to load payroll clients');
    } finally {
      if (shouldUpdate && requestId === companiesRequestIdRef.current) {
      setIsLoadingCompanies(false);
      setCompaniesLoadCount(count => count + 1);
      }
    }
  }, []);

  useEffect(() => {
    fetchUsers();
  }, [fetchUsers]);

  useEffect(() => {
    loadCompanies();
  }, [loadCompanies]);

  useEffect(() => {
    if (successMessage) {
      const timer = setTimeout(() => setSuccessMessage(null), 6000);
      return () => clearTimeout(timer);
    }
  }, [successMessage]);

  // --- New user form ---
  const handleStartAddNew = async () => {
    setIsAddingNew(true);
    setNewError(null);
    setNewFieldErrors({});
    setNewClientIds([]);
    // Practice copies finish preparing in the background, so a list loaded
    // earlier can be stale. Refresh whenever the picker opens.
    await loadCompanies();
  };

  const handleCancelAddNew = () => {
    setIsAddingNew(false);
    setNewName('');
    setNewEmail('');
    setNewRole('accountant');
    setNewClientAccess('manager');
    setNewError(null);
    setNewFieldErrors({});
    setNewClientIds([]);
  };

  const handleAddNew = async (): Promise<void> => {
    const companyIds = assignmentCompanyIdsForRole(newRole, newClientIds, availableCompanies);
    const fieldErrors = inviteFieldErrors(newEmail, newRole, companyIds);
    setNewFieldErrors(fieldErrors);
    setNewError(null);
    if (Object.keys(fieldErrors).length > 0) {
      document.getElementById(fieldErrors.email ? inviteEmailId : inviteClientsId)?.focus();
      return;
    }
    setIsSavingNew(true);
    try {
      const payload = {
        email: newEmail.trim(),
        name: newName.trim() || newEmail.trim().split('@')[0],
        role: newRole,
        ...(newRole === 'client' ? { client_access_level: newClientAccess } : {}),
        company_ids: companyIds,
      };
      const response = await usersApi.create(payload);
      setInviteWarning(null);
      if (invitationNeedsRetry(response)) {
        setSuccessMessage(null);
        setInviteWarning({ user: response.data, reason: inviteFailureReason(response), confirmedFailure: response.invitation_delivery_status === 'failed' });
      } else {
        setSuccessMessage(`Account created. ${invitationOutcomeMessage(response)}`);
      }

      handleCancelAddNew();
      await fetchUsers();
    } catch (err) {
      const serverFieldErrors = err instanceof ApiError ? inviteServerFieldErrors(err) : {};
      if (Object.keys(serverFieldErrors).length > 0) setNewFieldErrors(serverFieldErrors);
      else setNewError(err instanceof ApiError ? err.message : 'Could not create the user. Try again.');
    } finally {
      setIsSavingNew(false);
    }
  };

  // --- Resend invitation ---
  const handleResendInvitation = async (user: User): Promise<void> => {
    setResendingId(user.id);
    try {
      const response = await usersApi.resendInvitation(user.id);
      await fetchUsers();
      setError(null);
      setSuccessMessage(null);
      setInviteWarning(null);
      if (invitationNeedsRetry(response)) setInviteWarning({ user, reason: inviteFailureReason(response), confirmedFailure: response.invitation_delivery_status === 'failed' });
      else setSuccessMessage(invitationOutcomeMessage(response));
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to resend invitation';
      setError(message, errorCode(err) === 'practice_copy_closed' ? { user, move: true } : null);
    } finally {
      setResendingId(null);
    }
  };

  // --- Edit user ---
  const handleStartEdit = (user: User): void => {
    setEditingId(user.id);
    setEditName(user.name);
    setEditRole(user.role);
    setEditClientAccess(user.client_access_level ?? 'manager');
    setEditClientIds(user.assigned_company_ids || []);
    setEditError(null);
    void loadCompanies();
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) { setEditError('Name is required'); return; }
    setIsSavingEdit(true);
    setEditError(null);
    try {
      const editingUser = users.find(user => user.id === editingId);
      const loadedAccess = editingUser?.client_access_level ?? 'manager';
      const payload: {
        name: string; role: UserRole; client_access_level?: ClientAccessLevel; expected_client_access_level?: ClientAccessLevel; company_ids?: number[];
      } = {
        name: editName.trim(),
        role: editRole,
        // Only an access level the admin changed is sent, with the level they
        // saw, so a stale form can't quietly undo someone else's change.
        ...(editRole === 'client' && editClientAccess !== loadedAccess
          ? { client_access_level: editClientAccess, expected_client_access_level: loadedAccess }
          : {}),
      };

      if (editingUser?.practice_company_id) {
        // A practice-only login keeps exactly its own copy. A closed copy is
        // changed with Move, so a rename never touches its assignment.
        if (!editingUser.practice_copy_closed_reason) payload.company_ids = [editingUser.practice_company_id];
      } else {
        payload.company_ids = assignmentCompanyIdsForRole(editRole, editClientIds, availableCompanies);
      }

      await usersApi.update(editingId, payload);
      setEditingId(null);
      setEditClientIds([]);
      fetchUsers();
    } catch (err) {
      setEditError(err instanceof ApiError ? err.message : 'Failed to update user');
    } finally {
      setIsSavingEdit(false);
    }
  };

  const handleCancelEdit = (): void => {
    setEditingId(null);
    setEditClientIds([]);
    setEditError(null);
  };

  // --- Activate / Deactivate ---
  const handleToggleActive = async (user: User): Promise<void> => {
    setTogglingId(user.id);
    try {
      if (user.active === false) { await usersApi.activate(user.id); }
      else { await usersApi.deactivate(user.id); }
      setError(null);
      fetchUsers();
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to update user';
      setError(message, errorCode(err) === 'practice_copy_closed' ? { user, move: true } : null);
    } finally {
      setTogglingId(null);
    }
  };

  // --- Delete ---
  const handleDeleteUser = async (user: User): Promise<void> => {
    if (!window.confirm(`Are you sure you want to delete ${user.name} (${user.email})? This cannot be undone.`)) return;
    setDeletingId(user.id);
    try {
      await usersApi.delete(user.id);
      setError(null);
      setSuccessMessage(`${user.name} has been deleted`);
      fetchUsers();
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to delete user';
      setError(message, errorCode(err) === 'user_has_retained_history'
        ? { user, deactivate: user.active !== false, move: Boolean(user.practice_copy_closed_reason) }
        : null);
    } finally {
      setDeletingId(null);
    }
  };

  const handleMoved = ({ user, fromName, toName, invitation }: { user: User; fromName: string; toName: string; invitation?: InvitationDeliveryResponse }) => {
    setMoveUser(null);
    setError(null);
    setInviteWarning(null);
    const moved = `${user.name} now uses ${toName}. Their history in ${fromName} keeps their name.`;
    const inviteFailure = invitation && invitationNeedsRetry(invitation)
      ? `${moved} ${inviteFailureReason(invitation)} Use Resend on their row to try again.` : null;
    if (inviteFailure) {
      setSuccessMessage(null);
      setError(inviteFailure);
    } else {
      setSuccessMessage(`${moved}${user.active === false ? ' The login is still inactive.' : ''}${invitation ? ` ${invitationOutcomeMessage(invitation)}` : ''}`);
    }
    void fetchUsers({ keepFeedback: true }).then(refreshError => {
      if (refreshError) setError([inviteFailure, `The user list could not be refreshed: ${refreshError}`].filter(Boolean).join(' '));
    });
  };

  const openMove = (user: User) => {
    setError(null);
    setMoveUser(user);
    void loadCompanies();
  };

  const handleNewRoleChange = (role: UserRole): void => {
    setNewRole(role);
    setNewFieldErrors((current) => ({ email: current.email }));
    setNewClientIds(selectedIds => assignmentCompanyIdsForRole(role, selectedIds, availableCompanies));
    if (role === 'client') void loadCompanies();
  };

  const handleEditRoleChange = (role: UserRole): void => {
    setEditRole(role);
    setEditClientIds(selectedIds => assignmentCompanyIdsForRole(role, selectedIds, availableCompanies));
    if (role === 'client') void loadCompanies();
  };

  // A refreshed list can close a selected copy; keep only what is still valid.
  useEffect(() => {
    setNewClientIds(ids => {
      const next = assignmentCompanyIdsForRole(newRole, ids, availableCompanies);
      return sameIds(ids, next) ? ids : next;
    });
  }, [availableCompanies, newRole]);

  // While the picker shows a copy that is still being prepared, check again
  // after each load (failed ones included), for up to about three minutes.
  const pickerOpen = isAddingNew || editingId !== null;
  const hasPreparingCopy = availableCompanies.some(isPreparingPracticeCopy);
  const preparingPollsRef = useRef(0);
  useEffect(() => {
    if (!pickerOpen) preparingPollsRef.current = 0;
  }, [pickerOpen]);
  useEffect(() => {
    if (!pickerOpen || !hasPreparingCopy || preparingPollsRef.current >= 36) return;
    const timer = window.setTimeout(() => {
      preparingPollsRef.current += 1;
      void loadCompanies();
    }, 5000);
    return () => window.clearTimeout(timer);
  }, [pickerOpen, hasPreparingCopy, companiesLoadCount, loadCompanies]);

  const assignedCompaniesForUser = (user: User) =>
    needsClientAssignment(user.role) ? (user.assigned_companies || []) : [];

  const renderAssignedCompanies = (user: User) => {
    if (user.practice_company_id && user.practice_copy_closed_reason) {
      return (
        <div className="mt-1 flex flex-wrap gap-1.5">
          <span className="inline-flex items-center gap-1 rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 [overflow-wrap:anywhere]">
            <FlaskConical className="h-3 w-3" aria-hidden="true" />
            {user.practice_company_name || 'Practice copy'} · {user.practice_copy_closed_reason}
          </span>
        </div>
      );
    }
    const assignedCompanies = assignedCompaniesForUser(user);
    if (assignedCompanies.length === 0) {
      return needsClientAssignment(user.role) ? (
        <p className="mt-1 text-xs text-neutral-600">No assigned payroll clients</p>
      ) : null;
    }

    return (
      <div className="mt-1 flex flex-wrap gap-1.5">
        {assignedCompanies.map((company) => (
          <span
            key={company.id}
            className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-600 [overflow-wrap:anywhere]"
          >
            {company.name}{company.test_workspace ? user.role === 'client' ? ' · Practice copy only' : ` · ${company.workspace_access_level?.replace('_', ' ') || 'operator'}` : ''}
          </span>
        ))}
      </div>
    );
  };

  // A server refusal (practice_copy_closed) offers Move even when the loaded row
  // predates the copy closing; row actions rely on the loaded reason.
  const moveAction = (user: User, size: 'full' | 'compact' = 'full', refused = false) => refused || user.practice_copy_closed_reason ? (
    <Button size="sm" variant="outline" aria-label={`Move ${user.name} to another practice copy`} onClick={() => openMove(user)}>
      <ArrowRightLeft className="mr-1 h-4 w-4" aria-hidden="true" />
      {size === 'full' ? 'Move to practice copy' : 'Move'}
    </Button>
  ) : null;

  // A practice-only login is fixed to one copy. Edit shows that copy instead of
  // the picker; a closed copy is changed with Move.
  const renderPracticeLoginPanel = (user: User) => (
    <div className="rounded-lg border border-amber-200 bg-amber-50/60 p-3 text-sm text-neutral-700">
      <p className="flex items-center gap-2 font-medium text-neutral-900">
        <FlaskConical className="h-4 w-4 shrink-0 text-amber-700" aria-hidden="true" />
        Practice-only login for {user.practice_company_name || 'its practice copy'}
      </p>
      {user.practice_copy_closed_reason ? (
        <>
          <p className="mt-1">That copy is {user.practice_copy_closed_reason}. Move this login to a current practice copy to use it again.</p>
          <div className="mt-3">{moveAction(user)}</div>
        </>
      ) : (
        <p className="mt-1">It can reach only this copy, never a real client. Use a different email for anyone who needs real client access.</p>
      )}
    </div>
  );

  const renderAssignmentOption = (
    option: AssignmentOption,
    selectedIds: number[],
    setSelectedIds: Dispatch<SetStateAction<number[]>>,
    role: UserRole
  ) => {
    const { company } = option;
    const selected = selectedIds.includes(company.id);
    const disabled = !option.selectable && !selected;
    const isTest = isTestWorkspaceCompany(company);
    return (
      <label
        key={company.id}
        className={`flex items-center gap-2 rounded-lg border p-2 text-xs transition-colors ${
          disabled ? 'cursor-not-allowed border-neutral-200 bg-neutral-50 opacity-80'
            : selected ? 'cursor-pointer border-primary-300 bg-primary-50'
              : 'cursor-pointer border-neutral-200 bg-white hover:bg-neutral-50'
        }`}
      >
        <input
          type="checkbox"
          checked={selected}
          disabled={disabled}
          onChange={() => setSelectedIds(current => toggleAssignment(role, current, company, availableCompanies))}
          className="h-4 w-4 rounded border-neutral-300 text-primary-600 focus:ring-primary-500"
        />
        <div className="min-w-0">
          <p className="truncate font-medium text-neutral-900">{company.name}</p>
          <p className={`text-xs ${option.preparing ? 'text-primary-700' : isTest ? 'font-medium text-amber-700' : 'text-neutral-600'}`}>{option.detail}</p>
        </div>
      </label>
    );
  };

  const renderClientAssignmentPicker = (
    selectedIds: number[],
    setSelectedIds: Dispatch<SetStateAction<number[]>>,
    role: UserRole,
    summaryLabel?: string
  ) => {
    if (companiesLoadError && availableCompanies.length === 0) {
      return (
        <div className="rounded-lg border border-danger-200 bg-danger-50 p-3">
          <p className="text-sm text-danger-700">{companiesLoadError}</p>
          <div className="mt-3">
            <Button size="sm" variant="outline" onClick={() => void loadCompanies()} disabled={isLoadingCompanies}>
              {isLoadingCompanies ? 'Retrying...' : 'Retry'}
            </Button>
          </div>
        </div>
      );
    }

    if (isLoadingCompanies && availableCompanies.length === 0) {
      return <p className="text-sm text-neutral-500">Loading payroll clients...</p>;
    }

    const groups = groupAssignmentCompanies(availableCompanies, role, selectedIds);
    if (groups.production.length + groups.practice.length + groups.unavailable.length === 0) {
      return <p className="text-sm text-neutral-500">No payroll clients available.</p>;
    }
    const grid = 'grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3';
    const refreshing = isLoadingCompanies && availableCompanies.length > 0;

    return (
      <div className="space-y-4" aria-busy={refreshing || undefined}>
        {groups.production.length > 0 && (
          <section>
            <h4 className="mb-2 text-xs font-bold text-neutral-600">Production clients</h4>
            <div className={grid}>{groups.production.map(option => renderAssignmentOption(option, selectedIds, setSelectedIds, role))}</div>
          </section>
        )}
        <section>
          <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
            <h4 className="text-xs font-bold text-neutral-600">Test / practice workspaces</h4>
            <div className="flex items-center gap-2">
              <span role="status" className="text-xs text-neutral-500">{refreshing ? 'Checking for updates…' : ''}</span>
              <Button size="sm" variant="ghost" onClick={() => void loadCompanies()} disabled={isLoadingCompanies} aria-label="Refresh test and practice workspaces">
                <RefreshCw className={`mr-1 h-3.5 w-3.5 ${refreshing ? 'animate-spin' : ''}`} aria-hidden="true" />
                Refresh
              </Button>
            </div>
          </div>
          {role === 'client' && (
            <p className="mb-2 text-xs leading-5 text-neutral-600">
              For practice, use a separate email and choose one practice copy. This login cannot access real clients and is deactivated when the copy is archived or expires.
            </p>
          )}
          {groups.practice.length > 0 ? (
            <div className={grid}>{groups.practice.map(option => renderAssignmentOption(option, selectedIds, setSelectedIds, role))}</div>
          ) : (
            <p className="text-xs text-neutral-500">
              {role === 'client' ? 'No ready practice copies. Make one from Client Management.' : 'No open test workspaces.'}
            </p>
          )}
        </section>
        {groups.unavailable.length > 0 && (
          <details className="group">
            <summary className="flex cursor-pointer list-none items-center gap-1 text-xs font-semibold text-neutral-600 marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
              <ChevronDown className="h-3.5 w-3.5 transition-transform group-open:rotate-180" aria-hidden="true" />
              Archived, expired or read-only ({groups.unavailable.length})
            </summary>
            <p className="mb-2 mt-2 text-xs text-neutral-500">These can’t take new access.</p>
            <div className={grid}>{groups.unavailable.map(option => renderAssignmentOption(option, selectedIds, setSelectedIds, role))}</div>
          </details>
        )}
        {summaryLabel && (
          <p className="text-xs text-neutral-600">{summaryLabel}</p>
        )}
      </div>
    );
  };

  return (
    <div>
      <Header
        title="User Management"
        organizationWide
        description="Manage staff accounts, roles, and payroll client access"
        actions={
          !isAddingNew && (
            <Button onClick={handleStartAddNew}>
              <Plus className="w-4 h-4 mr-2" />
              Invite User
            </Button>
          )
        }
      />

      <div className="p-4 sm:p-6 lg:p-8">
        <RoleGuide roles={roleGuideOptions} />

        {error && (
          <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error}>
            <div className="space-y-2">
              <p className="flex gap-2 text-danger-700"><AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-danger-600" aria-hidden="true" />{error}</p>
              {errorActions && (errorActions.move || errorActions.deactivate) && (
                <div className="flex flex-wrap gap-2">
                  {errorActions.move && moveAction(errorActions.user, 'full', true)}
                  {errorActions.deactivate && (
                    <Button size="sm" variant="outline" onClick={() => void handleToggleActive(errorActions.user)} disabled={togglingId === errorActions.user.id}>
                      <UserX className="mr-1 h-4 w-4" aria-hidden="true" />Deactivate instead
                    </Button>
                  )}
                </div>
              )}
            </div>
          </ActionFeedback>
        )}

        {inviteWarning && (
          <ActionFeedback tone="warning" message={`Account created for ${inviteWarning.user.name || inviteWarning.user.email}, but ${inviteWarning.confirmedFailure ? 'the invitation was not sent' : 'the invitation could not be confirmed'}. ${inviteWarning.reason}`}>
            <div className="space-y-2">
              {inviteWarning.confirmedFailure
                ? <p><span className="font-semibold">{inviteWarning.user.name || inviteWarning.user.email}</span> has an account, but cannot sign in yet because no invitation was sent.</p>
                : <p><span className="font-semibold">{inviteWarning.user.name || inviteWarning.user.email}</span> has an account. We could not confirm whether the invitation was sent; check their status in the list below before retrying.</p>}
              <p className="text-amber-900">{inviteWarning.reason}</p>
              <Button size="sm" variant="outline" onClick={() => void handleResendInvitation(inviteWarning.user)} disabled={resendingId === inviteWarning.user.id}>
                <RefreshCw className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
                {resendingId === inviteWarning.user.id ? 'Retrying…' : 'Retry invitation'}
              </Button>
            </div>
          </ActionFeedback>
        )}

        {successMessage && (
          <ActionFeedback tone="success" message={successMessage}><Mail className="w-5 h-5 text-green-600 shrink-0 mt-0.5" />
            <p className="text-green-700">{successMessage}</p></ActionFeedback>
        )}

        {/* Invite New User Form */}
        {isAddingNew && (
          <Card className="mb-6 p-5">
            <h3 className="text-sm font-semibold text-neutral-900 mb-1">Invite New User</h3>
            <p className="text-xs text-neutral-600 mb-4">
              Create a pending account and request an invitation email. Their name will update from their profile when they accept.
            </p>
            {newError && (
              <ActionFeedback retryKey={newErrorFeedbackAttempt} tone="error" message={newError}><p className="text-sm text-danger-600">{newError}</p></ActionFeedback>
            )}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3 md:items-start">
              <Input id={inviteEmailId} label="Email address" type="email" autoComplete="off" required aria-required="true"
                value={newEmail} error={newFieldErrors.email}
                onChange={(e) => { setNewEmail(e.target.value); setNewFieldErrors((current) => ({ ...current, email: undefined })); }} />
              <Input label="Name (optional)" value={newName} onChange={(e) => setNewName(e.target.value)} />
              <Select label="Role" value={newRole} onChange={(e) => handleNewRoleChange(e.target.value as UserRole)}>
                {invitationRoleOptions.map((role) => (
                  <option key={role.value} value={role.value}>{role.label}</option>
                ))}
              </Select>
            </div>
            <RoleHint role={roleOptions.find((role) => role.value === newRole)} />
            {newRole === 'client' && <div className="mt-3 max-w-md"><ClientAccessField value={newClientAccess} onChange={setNewClientAccess} disabled={isSavingNew} /></div>}

            {needsClientAssignment(newRole) && (
              <div className="mt-4 pt-4 border-t border-neutral-200">
                <p id={inviteClientsId} tabIndex={-1} className="text-sm font-medium text-neutral-700 mb-2">
                  Assign Payroll Clients
                  <span className="text-xs font-normal text-neutral-600 ml-2">
                    {newRole === 'client' ? '(choose at least one)' : '(can also be changed later)'}
                  </span>
                </p>
                {newFieldErrors.clients && <p role="alert" className="mb-2 text-sm text-danger-600">{newFieldErrors.clients}</p>}
                {renderClientAssignmentPicker(
                  newClientIds,
                  (next) => { setNewClientIds(next); setNewFieldErrors((current) => ({ ...current, clients: undefined })); },
                  newRole,
                  newClientIds.length > 0 ? `${newClientIds.length} client${newClientIds.length !== 1 ? 's' : ''} selected` : undefined
                )}
              </div>
            )}

            <div className="mt-4 flex gap-2">
              <Button onClick={handleAddNew} disabled={isSavingNew}>
                <Mail className="w-4 h-4 mr-2" />
                {isSavingNew ? 'Sending...' : 'Send Invitation'}
              </Button>
              <Button variant="ghost" onClick={handleCancelAddNew} disabled={isSavingNew}>Cancel</Button>
            </div>
          </Card>
        )}

        {/* User List */}
        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="text-center">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600 mx-auto" />
              <p className="mt-2 text-sm text-neutral-500">Loading users...</p>
            </div>
          </div>
        ) : (
          <>
            <div className="space-y-3 sm:hidden">
              {users.map((user) => (
                <MobileRecordCard key={user.id}>
                  <div className="flex items-start gap-3">
                    <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
                      <UserCircle className="h-5 w-5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      {editingId === user.id ? (
                        <div className="space-y-3">
                          <Input aria-label="Name" value={editName} onChange={(e) => setEditName(e.target.value)} />
                          <Select aria-label="Role" value={editRole} disabled={Boolean(user.practice_company_id)} onChange={(e) => handleEditRoleChange(e.target.value as UserRole)}>
                            {editRoleOptions.map((role) => (
                              <option key={role.value} value={role.value}>{role.label}</option>
                            ))}
                          </Select>
                          {editRole === 'client' && <ClientAccessField value={editClientAccess} onChange={setEditClientAccess} disabled={isSavingEdit} />}
                          {user.practice_company_id ? renderPracticeLoginPanel(user) : needsClientAssignment(editRole) ? renderClientAssignmentPicker(editClientIds, setEditClientIds, editRole) : (
                            <p className="rounded-xl bg-neutral-50 p-3 text-sm text-neutral-500">
                              This role does not use payroll client assignments. Saving will clear any existing client assignments.
                            </p>
                          )}
                          {editError && <ActionFeedback retryKey={editErrorFeedbackAttempt} tone="error" message={editError} />}
                          <MobileCardActions className="mt-0 grid grid-cols-2">
                            <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                              <Check className="mr-1 h-4 w-4" />
                              {isSavingEdit ? 'Saving...' : 'Save'}
                            </Button>
                            <Button size="sm" variant="outline" aria-label={`Cancel editing ${user.name} (${user.email})`} onClick={handleCancelEdit} disabled={isSavingEdit}>Cancel</Button>
                          </MobileCardActions>
                        </div>
                      ) : (
                        <>
                          <div className="flex items-start justify-between gap-3">
                            <div className="min-w-0">
                              <p className="flex flex-wrap items-center gap-2 break-words font-semibold text-neutral-950">
                                {user.name}
                                {user.platform_owner && <OwnerBadge />}
                              </p>
                              <p className="break-all text-sm text-neutral-500">{user.email}</p>
                            </div>
                            <StatusBadges user={user} />
                          </div>
                          <div className="mt-4 grid grid-cols-2 gap-3">
                            <MobileField label="Role" value={userRoleLabel(user)} />
                            <MobileField label="Last active" value={user.last_active_at ? formatGuamDateTime(user.last_active_at, { second: undefined }) : '—'} />
                          </div>
                          <div className="mt-3">{renderAssignedCompanies(user)}</div>
                          <MobileCardActions>
                            <Button size="sm" variant="outline" onClick={() => setActivityUser(user)}><Activity className="mr-1 h-4 w-4" />Activity</Button>
                            {managementAction(user)}
                            {recoveryAction(user)}
                            {moveAction(user, 'compact')}
                            {!user.platform_owner && <Button size="sm" variant="outline" onClick={() => handleStartEdit(user)}>Edit</Button>}
                            {user.invitation_pending && (
                              <Button size="sm" variant="outline" onClick={() => handleResendInvitation(user)} disabled={resendingId === user.id}>
                                <RefreshCw className={`mr-1 h-4 w-4 ${resendingId === user.id ? 'animate-spin' : ''}`} />
                                Resend
                              </Button>
                            )}
                            {user.id !== currentUser?.id && !user.platform_owner && (
                              <>
                                <Button size="sm" variant="ghost" onClick={() => handleToggleActive(user)} disabled={togglingId === user.id || deletingId === user.id}>
                                  {user.active === false ? 'Activate' : 'Deactivate'}
                                </Button>
                                <Button size="sm" variant="ghost" className="text-danger-700" aria-label={`Delete user ${user.name} (${user.email})`} onClick={() => handleDeleteUser(user)} disabled={deletingId === user.id || togglingId === user.id}>
                                  Delete
                                </Button>
                              </>
                            )}
                          </MobileCardActions>
                        </>
                      )}
                    </div>
                  </div>
                </MobileRecordCard>
              ))}
            </div>
            <Card className="hidden sm:block">
              <Table className="[&_td]:px-4 [&_th]:px-4">
                <TableHeader>
                <TableRow>
                  <TableHead>User</TableHead>
                  <TableHead>Role</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Last Active</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {users.map((user) => (
                  <Fragment key={user.id}>
                    <TableRow>
                      <TableCell className="min-w-[11rem] whitespace-normal">
                        {editingId === user.id ? (
                          <Input aria-label="Name" value={editName} onChange={(e) => setEditName(e.target.value)} />
                        ) : (
                          <span className="flex flex-wrap items-center gap-2 font-medium text-neutral-900">
                            {user.name}
                            {user.platform_owner && <OwnerBadge />}
                          </span>
                        )}
                        <span className="mt-0.5 block break-all text-xs text-neutral-600">{user.email}</span>
                      </TableCell>
                      <TableCell className="min-w-[10rem] whitespace-normal">
                        {editingId === user.id ? (
                          <div className="space-y-2">
                            <Select aria-label="Role" value={editRole} disabled={Boolean(user.practice_company_id)} onChange={(e) => handleEditRoleChange(e.target.value as UserRole)}>
                              {editRoleOptions.map((role) => (
                                <option key={role.value} value={role.value}>{role.label}</option>
                              ))}
                            </Select>
                            {editRole === 'client' && <ClientAccessField value={editClientAccess} onChange={setEditClientAccess} disabled={isSavingEdit} />}
                          </div>
                        ) : (
                          <div>
                            <span className="inline-flex items-center gap-1.5">
                              {userRoleLabel(user)}
                            </span>
                            {renderAssignedCompanies(user)}
                          </div>
                        )}
                      </TableCell>
                      <TableCell>
                        <StatusBadges user={user} />
                      </TableCell>
                      <TableCell className="whitespace-nowrap text-neutral-600">
                        {user.last_active_at ? (
                          <time dateTime={user.last_active_at} title={formatGuamDateTime(user.last_active_at)}>
                            {formatGuamDateTime(user.last_active_at, { second: undefined })}
                          </time>
                        ) : '\u2014'}
                      </TableCell>
                      <TableCell className="text-right">
                        {editingId === user.id ? (
                          <div className="flex justify-end gap-2">
                            <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                              <Check className="w-4 h-4 mr-1" />
                              {isSavingEdit ? 'Saving...' : 'Save'}
                            </Button>
                            <Button size="sm" variant="ghost" aria-label={`Cancel editing ${user.name} (${user.email})`} onClick={handleCancelEdit} disabled={isSavingEdit}>
                              <X className="w-4 h-4" />
                            </Button>
                          </div>
                        ) : (
                          <div className="ml-auto flex min-w-[15rem] max-w-[24rem] flex-wrap justify-end gap-1.5 [&_button]:text-xs">
                            <Button size="sm" variant="outline" onClick={() => setActivityUser(user)}><Activity className="mr-1 h-4 w-4" />Activity</Button>
                            {managementAction(user)}
                            {recoveryAction(user)}
                            {moveAction(user, 'compact')}
                            {!user.platform_owner && <Button size="sm" variant="outline" onClick={() => handleStartEdit(user)}>Edit</Button>}
                            {user.invitation_pending && (
                              <Button
                                size="sm"
                                variant="outline"
                                onClick={() => handleResendInvitation(user)}
                                disabled={resendingId === user.id}
                              >
                                <RefreshCw className={`w-4 h-4 mr-1 ${resendingId === user.id ? 'animate-spin' : ''}`} />
                                Resend
                              </Button>
                            )}
                            {user.id !== currentUser?.id && !user.platform_owner && (
                              <>
                                <Button size="sm" variant="ghost" onClick={() => handleToggleActive(user)} disabled={togglingId === user.id || deletingId === user.id}>
                                  {togglingId === user.id ? (
                                    <span className="flex items-center"><div className="w-4 h-4 mr-1 animate-spin rounded-full border-2 border-neutral-300 border-t-neutral-600" />{user.active === false ? 'Activating...' : 'Deactivating...'}</span>
                                  ) : user.active === false ? (
                                    <span className="flex items-center"><UserCheck className="w-4 h-4 mr-1" />Activate</span>
                                  ) : (
                                    <span className="flex items-center text-danger-700"><UserX className="w-4 h-4 mr-1" />Deactivate</span>
                                  )}
                                </Button>
                                <Button size="sm" variant="ghost" aria-label={`Delete user ${user.name} (${user.email})`} onClick={() => handleDeleteUser(user)} disabled={deletingId === user.id || togglingId === user.id}>
                                  {deletingId === user.id ? (
                                    <div className="w-4 h-4 animate-spin rounded-full border-2 border-red-300 border-t-red-600" />
                                  ) : (
                                    <span className="flex items-center text-danger-700"><Trash2 className="w-4 h-4" /></span>
                                  )}
                                </Button>
                              </>
                            )}
                          </div>
                        )}
                        {editingId === user.id && editError && (
                          <ActionFeedback retryKey={editErrorFeedbackAttempt} tone="error" message={editError} />
                        )}
                      </TableCell>
                    </TableRow>

                    {/* Inline edit details row */}
                    {editingId === user.id && (
                      <TableRow>
                        <TableCell colSpan={5} className="bg-neutral-50 p-0">
                          <div className="px-6 py-4">
                            {user.practice_company_id ? renderPracticeLoginPanel(user) : needsClientAssignment(editRole) ? (
                              <>
                                <div className="mb-3 flex items-center justify-between">
                                  <p className="text-sm font-medium text-neutral-700">
                                    Payroll clients for <strong>{editName || user.name}</strong>
                                  </p>
                                  <span className="text-xs text-neutral-600">
                                    {editClientIds.length} selected
                                  </span>
                                </div>

                                {renderClientAssignmentPicker(editClientIds, setEditClientIds, editRole)}
                              </>
                            ) : (
                              <p className="text-sm text-neutral-500">
                                This role does not use payroll client assignments. Saving will clear any existing client assignments.
                              </p>
                            )}
                          </div>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                ))}
              </TableBody>
              </Table>
            </Card>
          </>
        )}
      </div>
      {managementUser && <ClientManagementDialog key={managementUser.id} accountant={managementUser} onClose={() => setManagementUser(null)} />}
      {moveUser && (
        <MovePracticeLoginDialog
          key={moveUser.id}
          user={moveUser}
          companies={availableCompanies}
          loadingCompanies={isLoadingCompanies}
          loadError={companiesLoadError}
          onRefreshCompanies={() => void loadCompanies()}
          onClose={() => setMoveUser(null)}
          onMoved={handleMoved}
        />
      )}
      {recoveryUser && (
        <RecoverClerkLoginDialog
          user={recoveryUser}
          onClose={() => setRecoveryUser(null)}
          onBound={(updated) => {
            setUsers((rows) => rows.map((row) => row.id === updated.id ? updated : row));
            setInviteWarning((warning) => warning?.user.id === updated.id ? null : warning);
            setError(null);
            setSuccessMessage(`Clerk account linked for ${updated.name}.`);
            setRecoveryUser(null);
          }}
        />
      )}
      {activityUser && <UserActivityPanel user={activityUser} onClose={handleCloseActivity} />}
    </div>
  );
}

function StatusBadges({ user }: { user: User }) {
  return (
    <span className="flex flex-wrap items-center gap-1.5">
      {user.active === false ? <Badge>Inactive</Badge> : <Badge variant="success">Active</Badge>}
      {user.invitation_pending && (
        <Badge variant="warning"><Mail className="mr-1 h-3 w-3" aria-hidden="true" />Pending invite</Badge>
      )}
    </span>
  );
}

function OwnerBadge() {
  return (
    <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary-50 px-2 py-0.5 text-xs font-semibold text-primary-700" title="Permanent primary platform owner">
      <ShieldCheck className="h-3 w-3" /> Primary owner
    </span>
  );
}
