import { useState, useEffect, useCallback, useRef, Fragment, type Dispatch, type SetStateAction } from 'react';
import { Plus, Check, X, AlertCircle, UserCheck, UserX, Mail, RefreshCw, Trash2, UserCircle, Activity, ShieldCheck } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
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
import type { User, UserRole } from '@/types';
import type { CompanyListItem } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import { UserActivityPanel } from '@/components/users/UserActivityPanel';
import {
  assignmentCompanyIdsForRole,
  isTestWorkspaceCompany,
  needsClientAssignment,
} from '@/lib/user-company-access';

interface RoleOption {
  value: UserRole;
  label: string;
  scope: string;
  can: string;
  cannot: string;
  assignment: string;
  legacy?: boolean;
  exceptional?: boolean;
}

const allRoleOptions: RoleOption[] = [
  { value: 'super_admin', label: 'Super Admin', scope: 'Every organization and client', can: 'Manage platform organizations, recover access, and perform every organization-admin action.', cannot: 'This is an exceptional platform role and should not be used for normal payroll work.', assignment: 'No client assignment required.', exceptional: true },
  { value: 'org_admin', label: 'Organization Admin', scope: 'Every client in their organization', can: 'Manage users, clients, tax configuration, audit history, client check controls, and payroll operations.', cannot: 'Cannot manage other organizations or platform-wide settings.', assignment: 'Automatically receives all organization clients.' },
  { value: 'admin', label: 'Organization Admin (legacy)', scope: 'Every client in their organization', can: 'Same access as Organization Admin.', cannot: 'Legacy role name retained for existing accounts; use Organization Admin for new invitations.', assignment: 'Automatically receives all organization clients.', legacy: true },
  { value: 'manager', label: 'Manager', scope: 'Only assigned payroll clients', can: 'Run payroll, manage employees, configure client settings, and manage the shared printer-profile library.', cannot: 'Cannot manage users, organization tax configuration, or organization-wide audit history.', assignment: 'At least one payroll client should be assigned.' },
  { value: 'accountant', label: 'Accountant', scope: 'Only assigned payroll clients', can: 'Run payroll, manage employees, view assigned-client history, and create, select, or copy printer profiles.', cannot: 'Cannot change client-wide settings, manage users, or edit another person’s printer profile.', assignment: 'At least one payroll client should be assigned.' },
  { value: 'client', label: 'Client Portal User', scope: 'Only assigned client portal workspaces', can: 'Maintain employee records, upload documents, review payroll and reports, and submit approvals or change requests.', cannot: 'Cannot enter the internal payroll workspace, print checks, or see firm-wide settings and audit history.', assignment: 'Assign only the client companies this person represents.' },
  { value: 'employee', label: 'Employee', scope: 'No payroll workspace access today', can: 'Reserved for a future employee self-service experience.', cannot: 'Cannot currently sign in to staff or client payroll workspaces.', assignment: 'Do not use for active access until the employee portal is released.' },
];

export function Users() {
  const { user: currentUser } = useAuth();
  const roleOptions = currentUser?.role === 'super_admin'
    ? allRoleOptions
    : allRoleOptions.filter((role) => role.value !== 'super_admin');
  const invitationRoleOptions = roleOptions.filter((role) => !role.legacy);
  const roleGuideOptions = roleOptions.filter((role) => !role.legacy);
  const roleLabel = (role: UserRole) => allRoleOptions.find((option) => option.value === role)?.label || role;

  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  // New user form
  const [isAddingNew, setIsAddingNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [newRole, setNewRole] = useState<UserRole>('accountant');
  const [newError, setNewError] = useState<string | null>(null);
  const [isSavingNew, setIsSavingNew] = useState(false);
  const [newClientIds, setNewClientIds] = useState<number[]>([]);
  const [availableCompanies, setAvailableCompanies] = useState<CompanyListItem[]>([]);
  const [isLoadingCompanies, setIsLoadingCompanies] = useState(false);
  const [companiesLoadError, setCompaniesLoadError] = useState<string | null>(null);
  const companiesRequestIdRef = useRef(0);

  // Edit user
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editRole, setEditRole] = useState<UserRole>('employee');
  const [editClientIds, setEditClientIds] = useState<number[]>([]);
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);
  const editRoleOptions = roleOptions.filter((role) => !role.legacy || editRole === role.value);

  const [resendingId, setResendingId] = useState<number | null>(null);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [togglingId, setTogglingId] = useState<number | null>(null);
  const [activityUser, setActivityUser] = useState<User | null>(null);
  const handleCloseActivity = useCallback(() => setActivityUser(null), []);

  const fetchUsers = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await usersApi.list();
      setUsers(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load users');
    } finally {
      setIsLoading(false);
    }
  }, []);

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
    setNewClientIds([]);
    if (availableCompanies.length === 0) {
      await loadCompanies();
    }
  };

  const handleCancelAddNew = () => {
    setIsAddingNew(false);
    setNewName('');
    setNewEmail('');
    setNewRole('accountant');
    setNewError(null);
    setNewClientIds([]);
  };

  const handleAddNew = async (): Promise<void> => {
    if (!newEmail.trim()) {
      setNewError('Email is required');
      return;
    }
    setIsSavingNew(true);
    setNewError(null);
    try {
      const payload = {
        email: newEmail.trim(),
        name: newName.trim() || newEmail.trim().split('@')[0],
        role: newRole,
        company_ids: assignmentCompanyIdsForRole(newRole, newClientIds, availableCompanies),
      };
      const response = await usersApi.create(payload);
      const createdUser = response.data;

      if (response.invitation_sent) {
        setSuccessMessage(`Invitation sent to ${createdUser.email}`);
      } else if (response.invitation_error) {
        setSuccessMessage(`User created, but invitation email failed: ${response.invitation_error}. You can resend it.`);
      } else {
        setSuccessMessage(`User created. Configure Resend to send invitation emails.`);
      }

      handleCancelAddNew();
      await fetchUsers();
    } catch (err) {
      setNewError(err instanceof ApiError ? err.message : 'Failed to create user');
    } finally {
      setIsSavingNew(false);
    }
  };

  // --- Resend invitation ---
  const handleResendInvitation = async (user: User): Promise<void> => {
    setResendingId(user.id);
    try {
      const response = await usersApi.resendInvitation(user.id);
      if (response.invitation_sent) {
        setSuccessMessage(`Invitation resent to ${user.email}`);
      } else {
        setError(response.invitation_error || 'Failed to resend invitation');
      }
      fetchUsers();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to resend invitation');
    } finally {
      setResendingId(null);
    }
  };

  // --- Edit user ---
  const handleStartEdit = (user: User): void => {
    setEditingId(user.id);
    setEditName(user.name);
    setEditRole(user.role);
    setEditClientIds(user.assigned_company_ids || []);
    setEditError(null);

    if (availableCompanies.length === 0) {
      void loadCompanies();
    }
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) { setEditError('Name is required'); return; }
    setIsSavingEdit(true);
    setEditError(null);
    try {
      const payload: { name: string; role: UserRole; company_ids?: number[] } = {
        name: editName.trim(),
        role: editRole,
      };

      payload.company_ids = assignmentCompanyIdsForRole(editRole, editClientIds, availableCompanies);

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
      fetchUsers();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update user');
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
      setSuccessMessage(`${user.name} has been deleted`);
      fetchUsers();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete user');
    } finally {
      setDeletingId(null);
    }
  };

  const toggleCompanySelection = (
    companyId: number,
    setSelectedIds: Dispatch<SetStateAction<number[]>>
  ): void => {
    setSelectedIds(prev =>
      prev.includes(companyId) ? prev.filter(id => id !== companyId) : [...prev, companyId]
    );
  };

  const handleNewRoleChange = (role: UserRole): void => {
    setNewRole(role);
    setNewClientIds(selectedIds => assignmentCompanyIdsForRole(role, selectedIds, availableCompanies));
  };

  const handleEditRoleChange = (role: UserRole): void => {
    setEditRole(role);
    setEditClientIds(selectedIds => assignmentCompanyIdsForRole(role, selectedIds, availableCompanies));
  };

  const assignedCompaniesForUser = (user: User) =>
    needsClientAssignment(user.role) ? (user.assigned_companies || []) : [];

  const renderAssignedCompanies = (user: User) => {
    const assignedCompanies = assignedCompaniesForUser(user);
    if (assignedCompanies.length === 0) {
      return needsClientAssignment(user.role) ? (
        <p className="mt-1 text-xs text-gray-400">No assigned payroll clients</p>
      ) : null;
    }

    return (
      <div className="mt-1 flex flex-wrap gap-1.5">
        {assignedCompanies.map((company) => (
          <span
            key={company.id}
            className="inline-flex items-center rounded-full bg-gray-100 px-2 py-0.5 text-[11px] font-medium text-gray-600"
          >
            {company.name}{company.test_workspace ? ` · ${company.workspace_access_level?.replace('_', ' ') || 'operator'}` : ''}
          </span>
        ))}
      </div>
    );
  };

  const renderClientAssignmentPicker = (
    selectedIds: number[],
    setSelectedIds: Dispatch<SetStateAction<number[]>>,
    role: UserRole,
    summaryLabel?: string
  ) => {
    const assignableCompanies = role === 'client'
      ? availableCompanies.filter(company => !isTestWorkspaceCompany(company))
      : availableCompanies;
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
      return <p className="text-sm text-gray-500">Loading payroll clients...</p>;
    }

    if (assignableCompanies.length === 0) {
      return <p className="text-sm text-gray-500">No payroll clients available.</p>;
    }

    return (
      <>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
          {assignableCompanies.map(company => {
            const testWorkspace = isTestWorkspaceCompany(company);
            return (
              <label
                key={company.id}
                className={`flex items-center gap-2 p-2 rounded-lg border cursor-pointer transition-colors text-sm ${
                  selectedIds.includes(company.id)
                    ? 'border-primary-300 bg-primary-50'
                    : 'border-gray-200 bg-white hover:bg-gray-50'
                }`}
              >
                <input
                  type="checkbox"
                  checked={selectedIds.includes(company.id)}
                  onChange={() => toggleCompanySelection(company.id, setSelectedIds)}
                  className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                />
                <div className="min-w-0">
                  <p className="font-medium text-gray-900 truncate">{company.name}</p>
                  <p className={`text-xs ${testWorkspace ? 'font-medium text-amber-700' : 'text-gray-500'}`}>
                    {testWorkspace ? `${company.test_workspace_purpose_label || 'Test workspace'} · operator access` : `${company.active_employees} employees`}
                  </p>
                </div>
              </label>
            );
          })}
        </div>
        {summaryLabel && (
          <p className="text-xs text-gray-500 mt-2">{summaryLabel}</p>
        )}
      </>
    );
  };

  return (
    <div>
      <Header
        title="User Management"
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
        {/* Role guide */}
        <section className="mb-6 overflow-hidden rounded-2xl border border-slate-200 bg-white">
          <div className="border-b border-slate-200 bg-slate-950 px-4 py-4 text-white">
            <h2 className="font-semibold">Choose the narrowest role that fits</h2>
            <p className="mt-1 text-sm leading-5 text-slate-300">Permissions are enforced by capability and organization scope. Client assignments further limit managers, accountants, and client portal users.</p>
          </div>
          <div className="divide-y divide-slate-200 sm:hidden">
            {roleGuideOptions.map((role) => (
              <details key={role.value} className="group bg-white px-4 py-4">
                <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-4 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
                  <span>
                    <span className="block font-semibold text-slate-950">{role.label}</span>
                    <span className="mt-0.5 block text-xs text-slate-500">{role.scope}</span>
                  </span>
                  <span className="text-xs font-semibold text-primary-700 group-open:hidden">View</span>
                  <span className="hidden text-xs font-semibold text-primary-700 group-open:inline">Close</span>
                </summary>
                <dl className="space-y-4 pb-2 pt-4 text-xs leading-5">
                  <div><dt className="font-semibold uppercase tracking-wide text-emerald-700">Can</dt><dd className="text-slate-700">{role.can}</dd></div>
                  <div><dt className="font-semibold uppercase tracking-wide text-rose-700">Cannot</dt><dd className="text-slate-700">{role.cannot}</dd></div>
                  <div><dt className="font-semibold uppercase tracking-wide text-slate-400">Assignment</dt><dd className="text-slate-700">{role.assignment}</dd></div>
                </dl>
              </details>
            ))}
          </div>
          <div className="hidden gap-px bg-slate-200 sm:grid sm:grid-cols-2 xl:grid-cols-3">
            {roleGuideOptions.map((role) => (
              <article key={role.value} className="bg-white p-4">
                <div className="flex items-center justify-between gap-4">
                  <h3 className="font-semibold text-slate-950">{role.label}</h3>
                  {role.exceptional && <span className="rounded-full bg-amber-100 px-2 py-1 text-[10px] font-bold uppercase tracking-wide text-amber-800">Exceptional</span>}
                </div>
                <dl className="mt-4 space-y-4 text-xs leading-5">
                  <div><dt className="font-semibold uppercase tracking-wide text-slate-400">Scope</dt><dd className="text-slate-700">{role.scope}</dd></div>
                  <div><dt className="font-semibold uppercase tracking-wide text-emerald-700">Can</dt><dd className="text-slate-700">{role.can}</dd></div>
                  <div><dt className="font-semibold uppercase tracking-wide text-rose-700">Cannot</dt><dd className="text-slate-700">{role.cannot}</dd></div>
                  <div><dt className="font-semibold uppercase tracking-wide text-slate-400">Assignment</dt><dd className="text-slate-700">{role.assignment}</dd></div>
                </dl>
              </article>
            ))}
          </div>
        </section>

        {error && (
          <div className="mb-6 p-4 bg-danger-50 border border-danger-200 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-danger-600 shrink-0 mt-0.5" />
            <p className="text-danger-700">{error}</p>
          </div>
        )}

        {successMessage && (
          <div className="mb-6 p-4 bg-green-50 border border-green-200 rounded-lg flex items-start gap-3">
            <Mail className="w-5 h-5 text-green-600 shrink-0 mt-0.5" />
            <p className="text-green-700">{successMessage}</p>
          </div>
        )}

        {/* Invite New User Form */}
        {isAddingNew && (
          <Card className="mb-6 p-5">
            <h3 className="text-sm font-semibold text-gray-900 mb-1">Invite New User</h3>
            <p className="text-xs text-gray-500 mb-4">
              An invitation will be sent via Clerk. Their name will update from their profile when they accept.
            </p>
            {newError && (
              <div className="mb-3 p-3 bg-danger-50 border border-danger-200 rounded-lg">
                <p className="text-sm text-danger-600">{newError}</p>
              </div>
            )}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
              <Input placeholder="Email address *" type="email" value={newEmail} onChange={(e) => setNewEmail(e.target.value)} />
              <Input placeholder="Name (optional)" value={newName} onChange={(e) => setNewName(e.target.value)} />
              <Select value={newRole} onChange={(e) => handleNewRoleChange(e.target.value as UserRole)}>
                {invitationRoleOptions.map((role) => (
                  <option key={role.value} value={role.value}>{role.label}</option>
                ))}
              </Select>
            </div>

            {needsClientAssignment(newRole) && (
              <div className="mt-4 pt-4 border-t border-gray-200">
                <p className="text-sm font-medium text-gray-700 mb-2">
                  Assign Payroll Clients
                  <span className="text-xs font-normal text-gray-400 ml-2">(can also be changed later)</span>
                </p>
                {renderClientAssignmentPicker(
                  newClientIds,
                  setNewClientIds,
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
              <p className="mt-2 text-sm text-gray-500">Loading users...</p>
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
                          <Input value={editName} onChange={(e) => setEditName(e.target.value)} />
                          <Select value={editRole} onChange={(e) => handleEditRoleChange(e.target.value as UserRole)}>
                            {editRoleOptions.map((role) => (
                              <option key={role.value} value={role.value}>{role.label}</option>
                            ))}
                          </Select>
                          {needsClientAssignment(editRole) ? renderClientAssignmentPicker(editClientIds, setEditClientIds, editRole) : (
                            <p className="rounded-xl bg-neutral-50 p-3 text-sm text-neutral-500">
                              This role does not use payroll client assignments. Saving will clear any existing client assignments.
                            </p>
                          )}
                          {editError && <p className="text-sm text-danger-600">{editError}</p>}
                          <MobileCardActions className="mt-0 grid grid-cols-2">
                            <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                              <Check className="mr-1 h-4 w-4" />
                              {isSavingEdit ? 'Saving...' : 'Save'}
                            </Button>
                            <Button size="sm" variant="outline" onClick={handleCancelEdit} disabled={isSavingEdit}>Cancel</Button>
                          </MobileCardActions>
                        </div>
                      ) : (
                        <>
                          <div className="flex items-start justify-between gap-3">
                            <div className="min-w-0">
                              <p className="flex items-center gap-2 truncate font-semibold text-neutral-950">
                                {user.name}
                                {user.platform_owner && <OwnerBadge />}
                              </p>
                              <p className="truncate text-sm text-neutral-500">{user.email}</p>
                            </div>
                            {user.active === false ? <span className="text-sm text-neutral-500">Inactive</span> : <span className="text-sm font-medium text-green-600">Active</span>}
                          </div>
                          {user.invitation_pending && (
                            <span className="mt-2 inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-1 text-xs font-semibold text-amber-700">
                              <Mail className="h-3 w-3" />
                              Pending invite
                            </span>
                          )}
                          <div className="mt-4 grid grid-cols-2 gap-3">
                            <MobileField label="Role" value={roleLabel(user.role)} />
                            <MobileField label="Last active" value={user.last_active_at ? new Date(user.last_active_at).toLocaleDateString() : '—'} />
                          </div>
                          <div className="mt-3">{renderAssignedCompanies(user)}</div>
                          <MobileCardActions>
                            <Button size="sm" variant="outline" onClick={() => setActivityUser(user)}><Activity className="mr-1 h-4 w-4" />Activity</Button>
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
                                <Button size="sm" variant="ghost" className="text-danger-700" onClick={() => handleDeleteUser(user)} disabled={deletingId === user.id || togglingId === user.id}>
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
              <Table>
                <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Email</TableHead>
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
                      <TableCell>
                        {editingId === user.id ? (
                          <Input value={editName} onChange={(e) => setEditName(e.target.value)} />
                        ) : (
                          <span className="flex items-center gap-2">
                            {user.name}
                            {user.platform_owner && <OwnerBadge />}
                            {user.invitation_pending && (
                              <span className="inline-flex items-center gap-1 text-xs bg-amber-100 text-amber-700 px-1.5 py-0.5 rounded font-medium">
                                <Mail className="w-3 h-3" />
                                Pending
                              </span>
                            )}
                          </span>
                        )}
                      </TableCell>
                      <TableCell>{user.email}</TableCell>
                      <TableCell>
                        {editingId === user.id ? (
                          <Select value={editRole} onChange={(e) => handleEditRoleChange(e.target.value as UserRole)}>
                            {editRoleOptions.map((role) => (
                              <option key={role.value} value={role.value}>{role.label}</option>
                            ))}
                          </Select>
                        ) : (
                          <div>
                            <span className="inline-flex items-center gap-1.5">
                              {roleLabel(user.role)}
                            </span>
                            {renderAssignedCompanies(user)}
                          </div>
                        )}
                      </TableCell>
                      <TableCell>
                        {user.active === false ? (
                          <span className="text-sm text-gray-500">Inactive</span>
                        ) : (
                          <span className="text-sm text-green-600">Active</span>
                        )}
                      </TableCell>
                      <TableCell>
                        {user.last_active_at ? new Date(user.last_active_at).toLocaleString() : '\u2014'}
                      </TableCell>
                      <TableCell className="text-right">
                        {editingId === user.id ? (
                          <div className="flex justify-end gap-2">
                            <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                              <Check className="w-4 h-4 mr-1" />
                              {isSavingEdit ? 'Saving...' : 'Save'}
                            </Button>
                            <Button size="sm" variant="ghost" onClick={handleCancelEdit} disabled={isSavingEdit}>
                              <X className="w-4 h-4" />
                            </Button>
                          </div>
                        ) : (
                          <div className="flex justify-end gap-2">
                            <Button size="sm" variant="outline" onClick={() => setActivityUser(user)}><Activity className="mr-1 h-4 w-4" />Activity</Button>
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
                                    <span className="flex items-center"><div className="w-4 h-4 mr-1 animate-spin rounded-full border-2 border-gray-300 border-t-gray-600" />{user.active === false ? 'Activating...' : 'Deactivating...'}</span>
                                  ) : user.active === false ? (
                                    <span className="flex items-center"><UserCheck className="w-4 h-4 mr-1" />Activate</span>
                                  ) : (
                                    <span className="flex items-center text-danger-700"><UserX className="w-4 h-4 mr-1" />Deactivate</span>
                                  )}
                                </Button>
                                <Button size="sm" variant="ghost" onClick={() => handleDeleteUser(user)} disabled={deletingId === user.id || togglingId === user.id}>
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
                          <p className="text-xs text-danger-600 mt-1 text-right">{editError}</p>
                        )}
                      </TableCell>
                    </TableRow>

                    {/* Inline edit details row */}
                    {editingId === user.id && (
                      <TableRow>
                        <TableCell colSpan={6} className="bg-gray-50 p-0">
                          <div className="px-6 py-4">
                            {needsClientAssignment(editRole) ? (
                              <>
                                <div className="mb-3 flex items-center justify-between">
                                  <p className="text-sm font-medium text-gray-700">
                                    Payroll clients for <strong>{editName || user.name}</strong>
                                  </p>
                                  <span className="text-xs text-gray-500">
                                    {editClientIds.length} selected
                                  </span>
                                </div>

                                {renderClientAssignmentPicker(editClientIds, setEditClientIds, editRole)}
                              </>
                            ) : (
                              <p className="text-sm text-gray-500">
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
      {activityUser && <UserActivityPanel user={activityUser} onClose={handleCloseActivity} />}
    </div>
  );
}

function OwnerBadge() {
  return (
    <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary-50 px-2 py-0.5 text-[11px] font-semibold text-primary-700" title="Permanent primary platform owner">
      <ShieldCheck className="h-3 w-3" /> Primary owner
    </span>
  );
}
