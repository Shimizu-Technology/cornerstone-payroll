import { useState, useEffect, useCallback, Fragment } from 'react';
import { Plus, Check, X, AlertCircle, UserCheck, UserX, Building2, Mail, RefreshCw, Trash2, ChevronUp } from 'lucide-react';
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
import { usersApi, companiesApi, companyAssignmentsApi, ApiError } from '@/services/api';
import type { User, UserRole } from '@/types';
import type { CompanyListItem, CompanyAssignment } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';

const roleOptions: { value: UserRole; label: string; description: string }[] = [
  { value: 'admin', label: 'Admin', description: 'Full access to all payroll clients, user management, tax config, and audit logs' },
  { value: 'manager', label: 'Manager', description: 'Can run payroll and manage employees for assigned clients' },
  { value: 'accountant', label: 'Accountant', description: 'Can manage employees and payroll operations for assigned clients' },
  { value: 'employee', label: 'Employee', description: 'View-only access (future: self-service portal)' },
];

const needsClientAssignment = (role: UserRole) => role === 'manager' || role === 'accountant';

export function Users() {
  const { user: currentUser, isAdmin } = useAuth();

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
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);

  const [resendingId, setResendingId] = useState<number | null>(null);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [togglingId, setTogglingId] = useState<number | null>(null);

  // Inline client assignment (for existing users)
  const [assigningUserId, setAssigningUserId] = useState<number | null>(null);
  const [assignCompanies, setAssignCompanies] = useState<CompanyListItem[]>([]);
  const [selectedCompanyIds, setSelectedCompanyIds] = useState<number[]>([]);
  const [isSavingAssignments, setIsSavingAssignments] = useState(false);
  const [assignmentError, setAssignmentError] = useState<string | null>(null);

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

  useEffect(() => {
    fetchUsers();
  }, [fetchUsers]);

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
    try {
      const res = await companiesApi.list();
      setAvailableCompanies(res.companies);
    } catch { /* non-blocking */ }
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
      };
      const response = await usersApi.create(payload);
      const createdUser = response.data;

      if (newClientIds.length > 0 && createdUser.id) {
        try { await companyAssignmentsApi.bulkUpdate(createdUser.id, newClientIds); } catch { /* non-blocking */ }
      }

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
    setEditError(null);
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) { setEditError('Name is required'); return; }
    setIsSavingEdit(true);
    setEditError(null);
    try {
      await usersApi.update(editingId, { name: editName.trim(), role: editRole });
      setEditingId(null);
      fetchUsers();
    } catch (err) {
      setEditError(err instanceof ApiError ? err.message : 'Failed to update user');
    } finally {
      setIsSavingEdit(false);
    }
  };

  const handleCancelEdit = (): void => { setEditingId(null); setEditError(null); };

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

  // --- Inline client assignment ---
  const handleToggleAssignments = async (user: User): Promise<void> => {
    if (assigningUserId === user.id) {
      setAssigningUserId(null);
      return;
    }
    setAssigningUserId(user.id);
    setAssignmentError(null);
    try {
      const [companiesRes, assignmentsRes] = await Promise.all([
        companiesApi.list(),
        companyAssignmentsApi.list(user.id),
      ]);
      setAssignCompanies(companiesRes.companies);
      setSelectedCompanyIds(assignmentsRes.data.map((a: CompanyAssignment) => a.company_id));
    } catch (err) {
      setAssignmentError(err instanceof Error ? err.message : 'Failed to load assignments');
    }
  };

  const handleToggleCompany = (companyId: number): void => {
    setSelectedCompanyIds(prev =>
      prev.includes(companyId) ? prev.filter(id => id !== companyId) : [...prev, companyId]
    );
  };

  const handleSaveAssignments = async (): Promise<void> => {
    if (!assigningUserId) return;
    setIsSavingAssignments(true);
    setAssignmentError(null);
    try {
      await companyAssignmentsApi.bulkUpdate(assigningUserId, selectedCompanyIds);
      setAssigningUserId(null);
      fetchUsers();
    } catch (err) {
      setAssignmentError(err instanceof Error ? err.message : 'Failed to save assignments');
    } finally {
      setIsSavingAssignments(false);
    }
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
                          <span className="inline-flex items-center gap-1.5">
                            {roleOptions.find((role) => role.value === user.role)?.label || user.role}
                            {user.assigned_company_ids && user.assigned_company_ids.length > 0 && (
                              <span className="text-xs text-gray-400">
                                ({user.assigned_company_ids.length} client{user.assigned_company_ids.length !== 1 ? 's' : ''})
                              </span>
                            )}
                          </span>
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
                            {isAdmin && needsClientAssignment(user.role) && (
                              <Button
                                size="sm"
                                variant={assigningUserId === user.id ? 'default' : 'outline'}
                                onClick={() => handleToggleAssignments(user)}
                              >
                                {assigningUserId === user.id ? (
                                  <><ChevronUp className="w-4 h-4 mr-1" />Clients</>
                                ) : (
                                  <><Building2 className="w-4 h-4 mr-1" />Clients</>
                                )}
                              </Button>
                            )}
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

                    {/* Inline client assignment row */}
                    {assigningUserId === user.id && (
                      <TableRow>
                        <TableCell colSpan={6} className="bg-gray-50 p-0">
                          <div className="px-6 py-4">
                            <div className="flex items-center justify-between mb-3">
                              <p className="text-sm font-medium text-gray-700">
                                Payroll clients for <strong>{user.name}</strong>
                              </p>
                              <div className="flex items-center gap-2">
                                <span className="text-xs text-gray-500">
                                  {selectedCompanyIds.length} selected
                                </span>
                                <Button size="sm" onClick={handleSaveAssignments} disabled={isSavingAssignments}>
                                  {isSavingAssignments ? 'Saving...' : 'Save'}
                                </Button>
                                <Button size="sm" variant="ghost" onClick={() => setAssigningUserId(null)}>
                                  Cancel
                                </Button>
                              </div>
                            </div>

                            {assignmentError && (
                              <div className="mb-3 p-2 bg-danger-50 border border-danger-200 rounded text-sm text-danger-700">
                                {assignmentError}
                              </div>
                            )}

                            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
                              {assignCompanies.map(company => (
                                <label
                                  key={company.id}
                                  className={`flex items-center gap-2.5 p-2.5 rounded-lg border cursor-pointer transition-colors text-sm ${
                                    selectedCompanyIds.includes(company.id)
                                      ? 'border-primary-300 bg-primary-50'
                                      : 'border-gray-200 bg-white hover:bg-gray-50'
                                  }`}
                                >
                                  <input
                                    type="checkbox"
                                    checked={selectedCompanyIds.includes(company.id)}
                                    onChange={() => handleToggleCompany(company.id)}
                                    className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                                  />
                                  <div className="min-w-0">
                                    <p className="font-medium text-gray-900 truncate">{company.name}</p>
                                    <p className="text-xs text-gray-500">{company.active_employees} employees</p>
                                  </div>
                                </label>
                              ))}
                            </div>
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
