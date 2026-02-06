import { useState, useEffect, useCallback } from 'react';
import { Plus, Check, X, AlertCircle, UserCheck, UserX } from 'lucide-react';
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
import { usersApi, userInvitationsApi, ApiError } from '@/services/api';
import type { User, UserRole } from '@/types';

const roleOptions: { value: UserRole; label: string }[] = [
  { value: 'admin', label: 'Admin' },
  { value: 'manager', label: 'Manager' },
  { value: 'employee', label: 'Employee' },
];

export function Users() {
  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [isAddingNew, setIsAddingNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [newRole, setNewRole] = useState<UserRole>('employee');
  const [newError, setNewError] = useState<string | null>(null);
  const [isSavingNew, setIsSavingNew] = useState(false);
  const [inviteUrl, setInviteUrl] = useState<string | null>(null);

  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editRole, setEditRole] = useState<UserRole>('employee');
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);

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

  const handleAddNew = async (): Promise<void> => {
    if (!newName.trim() || !newEmail.trim()) {
      setNewError('Name and email are required');
      return;
    }

    setIsSavingNew(true);
    setNewError(null);
    try {
      const response = await userInvitationsApi.create({
        name: newName.trim(),
        email: newEmail.trim(),
        role: newRole,
      });
      setInviteUrl(response.data.invite_url);
      setNewName('');
      setNewEmail('');
      setNewRole('employee');
      fetchUsers();
    } catch (err) {
      if (err instanceof ApiError) {
        setNewError(err.message);
      } else {
        setNewError('Failed to create user');
      }
    } finally {
      setIsSavingNew(false);
    }
  };

  const handleStartEdit = (user: User): void => {
    setEditingId(user.id);
    setEditName(user.name);
    setEditRole(user.role);
    setEditError(null);
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) {
      setEditError('Name is required');
      return;
    }

    setIsSavingEdit(true);
    setEditError(null);
    try {
      await usersApi.update(editingId, { name: editName.trim(), role: editRole });
      setEditingId(null);
      fetchUsers();
    } catch (err) {
      if (err instanceof ApiError) {
        setEditError(err.message);
      } else {
        setEditError('Failed to update user');
      }
    } finally {
      setIsSavingEdit(false);
    }
  };

  const handleCancelEdit = (): void => {
    setEditingId(null);
    setEditName('');
    setEditRole('employee');
    setEditError(null);
  };

  const handleToggleActive = async (user: User): Promise<void> => {
    try {
      if (user.active === false) {
        await usersApi.activate(user.id);
      } else {
        await usersApi.deactivate(user.id);
      }
      fetchUsers();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update user');
    }
  };

  return (
    <div>
      <Header
        title="User Management"
        description="Manage user accounts and roles"
        actions={
          !isAddingNew && (
            <Button onClick={() => setIsAddingNew(true)}>
              <Plus className="w-4 h-4 mr-2" />
              Add User
            </Button>
          )
        }
      />

      <div className="p-6 lg:p-8">
        {error && (
          <div className="mb-6 p-4 bg-danger-50 border border-danger-200 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-danger-600 shrink-0 mt-0.5" />
            <p className="text-danger-700">{error}</p>
          </div>
        )}

        {isAddingNew && (
          <Card className="mb-6 p-4">
            <h3 className="text-sm font-medium text-gray-900 mb-3">Add New User</h3>
            {newError && (
              <p className="text-sm text-danger-600 mb-2">{newError}</p>
            )}
            {inviteUrl && (
              <p className="text-sm text-gray-600 mb-2">
                Invite created. Share this link if email delivery is not configured:
                <span className="ml-1 text-primary-700 break-all">{inviteUrl}</span>
              </p>
            )}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
              <Input
                placeholder="Full name (optional)"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
              />
              <Input
                placeholder="Email address"
                type="email"
                value={newEmail}
                onChange={(e) => setNewEmail(e.target.value)}
              />
              <Select
                value={newRole}
                onChange={(e) => setNewRole(e.target.value as UserRole)}
              >
                {roleOptions.map((role) => (
                  <option key={role.value} value={role.value}>{role.label}</option>
                ))}
              </Select>
            </div>
            <div className="mt-3 flex gap-2">
              <Button size="sm" onClick={handleAddNew} disabled={isSavingNew}>
                <Check className="w-4 h-4 mr-1" />
                {isSavingNew ? 'Saving...' : 'Save'}
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setIsAddingNew(false)} disabled={isSavingNew}>
                <X className="w-4 h-4" />
              </Button>
            </div>
          </Card>
        )}

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
                  <TableRow key={user.id}>
                    <TableCell>
                      {editingId === user.id ? (
                        <Input
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                        />
                      ) : (
                        user.name
                      )}
                    </TableCell>
                    <TableCell>{user.email}</TableCell>
                    <TableCell>
                      {editingId === user.id ? (
                        <Select
                          value={editRole}
                          onChange={(e) => setEditRole(e.target.value as UserRole)}
                        >
                          {roleOptions.map((role) => (
                            <option key={role.value} value={role.value}>{role.label}</option>
                          ))}
                        </Select>
                      ) : (
                        roleOptions.find((role) => role.value === user.role)?.label || user.role
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
                      {user.last_login_at ? new Date(user.last_login_at).toLocaleString() : '—'}
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
                          <Button size="sm" variant="outline" onClick={() => handleStartEdit(user)}>
                            Edit
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => handleToggleActive(user)}
                          >
                            {user.active === false ? (
                              <span className="flex items-center">
                                <UserCheck className="w-4 h-4 mr-1" />
                                Activate
                              </span>
                            ) : (
                              <span className="flex items-center text-danger-700">
                                <UserX className="w-4 h-4 mr-1" />
                                Deactivate
                              </span>
                            )}
                          </Button>
                        </div>
                      )}
                      {editingId === user.id && editError && (
                        <p className="text-xs text-danger-600 mt-1 text-right">{editError}</p>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>
        )}
      </div>
    </div>
  );
}
