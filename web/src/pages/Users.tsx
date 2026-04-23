import { useState, useEffect, useCallback, Fragment, type Dispatch, type SetStateAction } from 'react';
import { Plus, Check, X, AlertCircle, UserCheck, UserX, Mail, RefreshCw, Trash2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
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

const roleOptions: { value: UserRole; label: string; description: string }[] = [
  { value: 'admin', label: 'Admin', description: 'Full access to all payroll clients, user management, tax config, and audit logs' },
  { value: 'manager', label: 'Manager', description: 'Can run payroll and manage employees for assigned clients' },
  { value: 'accountant', label: 'Accountant', description: 'Can manage employees and payroll operations for assigned clients' },
  { value: 'employee', label: 'Employee', description: 'View-only access (future: self-service portal)' },
];

const needsClientAssignment = (role: UserRole) => role === 'manager' || role === 'accountant';

export function Users() {
  const { user: currentUser } = useAuth();

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

  // Edit user
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editRole, setEditRole] = useState<UserRole>('employee');
  const [editClientIds, setEditClientIds] = useState<number[]>([]);
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);

  const [resendingId, setResendingId] = useState<number | null>(null);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [togglingId, setTogglingId] = useState<number | null>(null);

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
    try {
      const res = await companiesApi.list();
      setAvailableCompanies(res.companies);
    } catch {
      // Non-blocking. User management remains usable without preloading clients.
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
        company_ids: needsClientAssignment(newRole) ? newClientIds : [],
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
  const handleStartEdit = async (user: User): Promise<void> => {
    if (availableCompanies.length === 0) {
      await loadCompanies();
    }
    setEditingId(user.id);
    setEditName(user.name);
    setEditRole(user.role);
    setEditClientIds(user.assigned_company_ids || []);
    setEditError(null);
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) { setEditError('Name is required'); return; }
    setIsSavingEdit(true);
    setEditError(null);
    try {
      await usersApi.update(editingId, {
        name: editName.trim(),
        role: editRole,
        company_ids: needsClientAssignment(editRole) ? editClientIds : [],
      });
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
            {company.name}
          </span>
        ))}
      </div>
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

      <div className="p-6 lg:p-8">
        {/* Role Descriptions */}
        <div className="mb-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
          <h4 className="text-sm font-semibold text-blue-900 mb-2">Role Permissions</h4>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
            {roleOptions.map(role => (
              <div key={role.value} className="flex items-start gap-2">
                <span className="text-xs font-bold text-blue-700 bg-blue-100 px-2 py-0.5 rounded mt-0.5 shrink-0 w-24 text-center">
                  {role.label}
                </span>
                <span className="text-xs text-blue-800">{role.description}</span>
              </div>
            ))}
          </div>
          <p className="text-xs text-blue-600 mt-2">
            Managers and accountants must be assigned specific payroll clients.
            Admins automatically have access to all clients.
          </p>
        </div>

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
              <Select value={newRole} onChange={(e) => setNewRole(e.target.value as UserRole)}>
                {roleOptions.map((role) => (
                  <option key={role.value} value={role.value}>{role.label}</option>
                ))}
              </Select>
            </div>

            {needsClientAssignment(newRole) && availableCompanies.length > 0 && (
              <div className="mt-4 pt-4 border-t border-gray-200">
                <p className="text-sm font-medium text-gray-700 mb-2">
                  Assign Payroll Clients
                  <span className="text-xs font-normal text-gray-400 ml-2">(can also be changed later)</span>
                </p>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
                  {availableCompanies.map(company => (
                    <label
                      key={company.id}
                      className={`flex items-center gap-2.5 p-2.5 rounded-lg border cursor-pointer transition-colors text-sm ${
                        newClientIds.includes(company.id) ? 'border-primary-300 bg-primary-50' : 'border-gray-200 hover:bg-gray-50'
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={newClientIds.includes(company.id)}
                        onChange={() => setNewClientIds(prev => prev.includes(company.id) ? prev.filter(id => id !== company.id) : [...prev, company.id])}
                        className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                      />
                      <div className="min-w-0">
                        <p className="font-medium text-gray-900 truncate">{company.name}</p>
                        <p className="text-xs text-gray-500">{company.active_employees} employees</p>
                      </div>
                    </label>
                  ))}
                </div>
                {newClientIds.length > 0 && (
                  <p className="text-xs text-gray-500 mt-2">{newClientIds.length} client{newClientIds.length !== 1 ? 's' : ''} selected</p>
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
          <Card>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Email</TableHead>
                  <TableHead>Role</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Last Login</TableHead>
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
                          <Select value={editRole} onChange={(e) => setEditRole(e.target.value as UserRole)}>
                            {roleOptions.map((role) => (
                              <option key={role.value} value={role.value}>{role.label}</option>
                            ))}
                          </Select>
                        ) : (
                          <div>
                            <span className="inline-flex items-center gap-1.5">
                              {roleOptions.find((role) => role.value === user.role)?.label || user.role}
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
                        {user.last_login_at ? new Date(user.last_login_at).toLocaleString() : '\u2014'}
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
                            <Button size="sm" variant="outline" onClick={() => handleStartEdit(user)}>Edit</Button>
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
                            {user.id !== currentUser?.id && (
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

                                {availableCompanies.length > 0 ? (
                                  <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
                                    {availableCompanies.map(company => (
                                      <label
                                        key={company.id}
                                        className={`flex items-center gap-2.5 p-2.5 rounded-lg border cursor-pointer transition-colors text-sm ${
                                          editClientIds.includes(company.id)
                                            ? 'border-primary-300 bg-primary-50'
                                            : 'border-gray-200 bg-white hover:bg-gray-50'
                                        }`}
                                      >
                                        <input
                                          type="checkbox"
                                          checked={editClientIds.includes(company.id)}
                                          onChange={() => toggleCompanySelection(company.id, setEditClientIds)}
                                          className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                                        />
                                        <div className="min-w-0">
                                          <p className="font-medium text-gray-900 truncate">{company.name}</p>
                                          <p className="text-xs text-gray-500">{company.active_employees} employees</p>
                                        </div>
                                      </label>
                                    ))}
                                  </div>
                                ) : (
                                  <p className="text-sm text-gray-500">Loading payroll clients...</p>
                                )}
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
        )}
      </div>
    </div>
  );
}
