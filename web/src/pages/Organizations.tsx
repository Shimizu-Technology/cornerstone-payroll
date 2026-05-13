import { useCallback, useEffect, useState } from 'react';
import { AlertCircle, Building2, Check, Mail, Pencil, Plus, RefreshCw, ShieldCheck, Trash2, UserCheck, UserX, X } from 'lucide-react';
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
import { ApiError, organizationsApi, usersApi, type OrganizationAdminSummary, type OrganizationSummary } from '@/services/api';
import type { PaginationMeta } from '@/types';

export function Organizations() {
  const [organizations, setOrganizations] = useState<OrganizationSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  const [isAdding, setIsAdding] = useState(false);
  const [isSavingNew, setIsSavingNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newSlug, setNewSlug] = useState('');
  const [newPrimaryCompanyName, setNewPrimaryCompanyName] = useState('');
  const [newClientLimit, setNewClientLimit] = useState('3');
  const [newUnlimitedClients, setNewUnlimitedClients] = useState(false);
  const [newAdminName, setNewAdminName] = useState('');
  const [newAdminEmail, setNewAdminEmail] = useState('');
  const [newError, setNewError] = useState<string | null>(null);

  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editSlug, setEditSlug] = useState('');
  const [editStatus, setEditStatus] = useState<'active' | 'inactive'>('active');
  const [editClientLimit, setEditClientLimit] = useState('3');
  const [editUnlimitedClients, setEditUnlimitedClients] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);

  const [adminOrgId, setAdminOrgId] = useState<number | null>(null);
  const [adminName, setAdminName] = useState('');
  const [adminEmail, setAdminEmail] = useState('');
  const [adminError, setAdminError] = useState<string | null>(null);
  const [isSavingAdmin, setIsSavingAdmin] = useState(false);
  const [adminActionId, setAdminActionId] = useState<number | null>(null);

  const fetchOrganizations = useCallback(async (nextPage = page) => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await organizationsApi.list({ page: nextPage, per_page: 25 });
      setOrganizations(response.data);
      setMeta(response.meta ?? null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load organizations');
    } finally {
      setIsLoading(false);
    }
  }, [page]);

  useEffect(() => {
    void fetchOrganizations();
  }, [fetchOrganizations]);

  useEffect(() => {
    if (!successMessage) return;
    const timer = setTimeout(() => setSuccessMessage(null), 6000);
    return () => clearTimeout(timer);
  }, [successMessage]);

  const parseClientLimit = (value: string) => {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : 0;
  };

  const resetNewForm = () => {
    setIsAdding(false);
    setNewName('');
    setNewSlug('');
    setNewPrimaryCompanyName('');
    setNewClientLimit('3');
    setNewUnlimitedClients(false);
    setNewAdminName('');
    setNewAdminEmail('');
    setNewError(null);
  };

  const handleCreateOrganization = async () => {
    if (!newName.trim()) {
      setNewError('Organization name is required');
      return;
    }
    if (!newPrimaryCompanyName.trim()) {
      setNewError('Primary company name is required');
      return;
    }
    if (!newAdminEmail.trim()) {
      setNewError('First admin email is required');
      return;
    }
    if (!newUnlimitedClients && parseClientLimit(newClientLimit) < 1) {
      setNewError('Client limit must be at least 1, or choose unlimited');
      return;
    }

    setIsSavingNew(true);
    setNewError(null);
    try {
      const response = await organizationsApi.create({
        name: newName.trim(),
        slug: newSlug.trim() || undefined,
        client_limit: newUnlimitedClients ? null : parseClientLimit(newClientLimit),
        unlimited_clients: newUnlimitedClients,
        primary_company_name: newPrimaryCompanyName.trim(),
        admin: {
          email: newAdminEmail.trim(),
          name: newAdminName.trim() || undefined,
        },
      });

      if (response.invitation_sent) {
        setSuccessMessage(`Organization created and invitation sent to ${response.admin_user?.email}`);
      } else if (response.invitation_error) {
        setSuccessMessage(`Organization created, but invitation email failed: ${response.invitation_error}`);
      } else {
        setSuccessMessage('Organization created');
      }
      resetNewForm();
      setPage(1);
      await fetchOrganizations(1);
    } catch (err) {
      setNewError(err instanceof ApiError ? err.message : 'Failed to create organization');
    } finally {
      setIsSavingNew(false);
    }
  };

  const handleStartEdit = (organization: OrganizationSummary) => {
    setEditingId(organization.id);
    setEditName(organization.name);
    setEditSlug(organization.slug);
    setEditStatus(organization.status);
    setEditUnlimitedClients(organization.unlimited_clients);
    setEditClientLimit(String(organization.client_limit ?? 3));
    setEditError(null);
  };

  const handleSaveEdit = async () => {
    if (!editingId || !editName.trim()) {
      setEditError('Organization name is required');
      return;
    }
    if (!editUnlimitedClients && parseClientLimit(editClientLimit) < 1) {
      setEditError('Client limit must be at least 1, or choose unlimited');
      return;
    }

    setIsSavingEdit(true);
    setEditError(null);
    try {
      await organizationsApi.update(editingId, {
        name: editName.trim(),
        slug: editSlug.trim(),
        status: editStatus,
        client_limit: editUnlimitedClients ? null : parseClientLimit(editClientLimit),
        unlimited_clients: editUnlimitedClients,
      });
      setEditingId(null);
      setSuccessMessage('Organization updated');
      await fetchOrganizations();
    } catch (err) {
      setEditError(err instanceof ApiError ? err.message : 'Failed to update organization');
    } finally {
      setIsSavingEdit(false);
    }
  };

  const handleStartAdmin = (organization: OrganizationSummary) => {
    setAdminOrgId(organization.id);
    setAdminName('');
    setAdminEmail('');
    setAdminError(null);
  };

  const handleCreateAdmin = async () => {
    if (!adminOrgId) return;
    if (!adminEmail.trim()) {
      setAdminError('Admin email is required');
      return;
    }

    setIsSavingAdmin(true);
    setAdminError(null);
    try {
      const response = await organizationsApi.createAdminUser(adminOrgId, {
        email: adminEmail.trim(),
        name: adminName.trim() || undefined,
      });
      if (response.invitation_sent) {
        setSuccessMessage(`Invitation sent to ${response.data.email}`);
      } else if (response.invitation_error) {
        setSuccessMessage(`Admin created, but invitation email failed: ${response.invitation_error}`);
      } else {
        setSuccessMessage('Organization admin created');
      }
      setAdminOrgId(null);
      await fetchOrganizations();
    } catch (err) {
      setAdminError(err instanceof ApiError ? err.message : 'Failed to create organization admin');
    } finally {
      setIsSavingAdmin(false);
    }
  };

  const handleRenameAdmin = async (admin: OrganizationAdminSummary) => {
    const nextName = window.prompt('Admin name', admin.name);
    if (nextName === null) return;
    const trimmed = nextName.trim();
    if (!trimmed || trimmed === admin.name) return;

    setAdminActionId(admin.id);
    setError(null);
    try {
      await usersApi.update(admin.id, { name: trimmed });
      setSuccessMessage('Organization admin updated');
      await fetchOrganizations();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to update organization admin');
    } finally {
      setAdminActionId(null);
    }
  };

  const handleToggleAdminActive = async (admin: OrganizationAdminSummary) => {
    setAdminActionId(admin.id);
    setError(null);
    try {
      if (admin.active === false) {
        await usersApi.activate(admin.id);
        setSuccessMessage('Organization admin activated');
      } else {
        await usersApi.deactivate(admin.id);
        setSuccessMessage('Organization admin deactivated');
      }
      await fetchOrganizations();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to update organization admin');
    } finally {
      setAdminActionId(null);
    }
  };

  const handleDeleteAdmin = async (admin: OrganizationAdminSummary) => {
    if (!window.confirm(`Delete ${admin.email}?`)) return;

    setAdminActionId(admin.id);
    setError(null);
    try {
      await usersApi.delete(admin.id);
      setSuccessMessage('Organization admin deleted');
      await fetchOrganizations();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to delete organization admin');
    } finally {
      setAdminActionId(null);
    }
  };

  const activeCount = organizations.filter((org) => org.status === 'active').length;
  const totalCompanies = organizations.reduce((sum, org) => sum + org.companies_count, 0);
  const totalUsers = organizations.reduce((sum, org) => sum + org.users_count, 0);
  const totalOrganizations = meta?.total_count ?? organizations.length;

  return (
    <div>
      <Header
        title="Organizations"
        description="Manage accounting firm workspaces and their administrators"
        actions={
          <Button onClick={() => setIsAdding(true)} disabled={isAdding}>
            <Plus className="mr-2 h-4 w-4" />
            New Organization
          </Button>
        }
      />

      <div className="p-6 lg:p-8">
        <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-3">
          <Card className="p-4">
            <div className="flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary-50 text-primary-700">
                <Building2 className="h-5 w-5" />
              </div>
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Organizations</p>
                <p className="text-2xl font-semibold text-neutral-900">{totalOrganizations}</p>
              </div>
            </div>
          </Card>
          <Card className="p-4">
            <div className="flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-green-50 text-green-700">
                <Check className="h-5 w-5" />
              </div>
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Active on Page</p>
                <p className="text-2xl font-semibold text-neutral-900">{activeCount}</p>
              </div>
            </div>
          </Card>
          <Card className="p-4">
            <div className="flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-blue-50 text-blue-700">
                <ShieldCheck className="h-5 w-5" />
              </div>
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Clients on Page</p>
                <p className="text-2xl font-semibold text-neutral-900">{totalCompanies}</p>
                <p className="text-xs text-neutral-500">{totalUsers} users</p>
              </div>
            </div>
          </Card>
        </div>

        {error && (
          <div className="mb-6 flex items-start gap-3 rounded-lg border border-danger-200 bg-danger-50 p-4">
            <AlertCircle className="mt-0.5 h-5 w-5 shrink-0 text-danger-600" />
            <p className="text-danger-700">{error}</p>
          </div>
        )}

        {successMessage && (
          <div className="mb-6 flex items-start gap-3 rounded-lg border border-green-200 bg-green-50 p-4">
            <Mail className="mt-0.5 h-5 w-5 shrink-0 text-green-600" />
            <p className="text-green-700">{successMessage}</p>
          </div>
        )}

        {isAdding && (
          <Card className="mb-6 p-5">
            <div className="mb-4 flex items-start justify-between gap-4">
              <div>
                <h3 className="text-sm font-semibold text-neutral-900">New Organization</h3>
                <p className="mt-1 text-xs text-neutral-500">
                  This creates the firm workspace, its first company, and a pending org admin.
                </p>
              </div>
              <Button variant="ghost" size="sm" onClick={resetNewForm} disabled={isSavingNew}>
                <X className="h-4 w-4" />
              </Button>
            </div>
            {newError && (
              <div className="mb-4 rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-700">
                {newError}
              </div>
            )}
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
              <Input placeholder="Organization name *" value={newName} onChange={(event) => setNewName(event.target.value)} />
              <Input placeholder="Slug (optional)" value={newSlug} onChange={(event) => setNewSlug(event.target.value)} />
              <Input placeholder="Primary company name *" value={newPrimaryCompanyName} onChange={(event) => setNewPrimaryCompanyName(event.target.value)} />
              <div className="flex items-center gap-3">
                <Input
                  placeholder="Client limit"
                  type="number"
                  min={1}
                  value={newClientLimit}
                  onChange={(event) => setNewClientLimit(event.target.value)}
                  disabled={newUnlimitedClients}
                />
                <label className="flex shrink-0 items-center gap-2 text-sm text-neutral-700">
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-neutral-300 text-primary-600 focus:ring-primary-500"
                    checked={newUnlimitedClients}
                    onChange={(event) => setNewUnlimitedClients(event.target.checked)}
                  />
                  Unlimited
                </label>
              </div>
              <Input placeholder="First admin email *" type="email" value={newAdminEmail} onChange={(event) => setNewAdminEmail(event.target.value)} />
              <Input placeholder="First admin name (optional)" value={newAdminName} onChange={(event) => setNewAdminName(event.target.value)} />
            </div>
            <div className="mt-4 flex gap-2">
              <Button onClick={handleCreateOrganization} disabled={isSavingNew}>
                {isSavingNew ? 'Creating...' : 'Create Organization'}
              </Button>
              <Button variant="ghost" onClick={resetNewForm} disabled={isSavingNew}>Cancel</Button>
            </div>
          </Card>
        )}

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="text-center">
              <RefreshCw className="mx-auto h-8 w-8 animate-spin text-primary-600" />
              <p className="mt-2 text-sm text-neutral-500">Loading organizations...</p>
            </div>
          </div>
        ) : (
          <Card className="overflow-hidden">
            <Table className="min-w-[1280px]" containerClassName="overflow-x-auto">
              <TableHeader>
                <TableRow>
                  <TableHead className="w-[300px]">Organization</TableHead>
                  <TableHead className="w-[170px]">Status</TableHead>
                  <TableHead className="w-[220px]">Clients</TableHead>
                  <TableHead className="w-[110px]">Users</TableHead>
                  <TableHead className="w-[360px]">Org Admins</TableHead>
                  <TableHead className="w-[260px] text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {organizations.map((organization) => (
                  <TableRow key={organization.id}>
                    <TableCell>
                      {editingId === organization.id ? (
                        <div className="space-y-2">
                          <Input className="w-64" value={editName} onChange={(event) => setEditName(event.target.value)} />
                          <Input className="w-64" value={editSlug} onChange={(event) => setEditSlug(event.target.value)} />
                          {editError && <p className="text-xs text-danger-600">{editError}</p>}
                        </div>
                      ) : (
                        <div>
                          <p className="font-medium text-neutral-900">{organization.name}</p>
                          <p className="text-xs text-neutral-500">{organization.slug}</p>
                        </div>
                      )}
                    </TableCell>
                    <TableCell>
                      {editingId === organization.id ? (
                        <Select value={editStatus} onChange={(event) => setEditStatus(event.target.value as 'active' | 'inactive')}>
                          <option value="active">Active</option>
                          <option value="inactive">Inactive</option>
                        </Select>
                      ) : (
                        <span className={organization.status === 'active' ? 'text-sm text-green-700' : 'text-sm text-neutral-500'}>
                          {organization.status === 'active' ? 'Active' : 'Inactive'}
                        </span>
                      )}
                    </TableCell>
                    <TableCell>
                      {editingId === organization.id ? (
                        <div className="space-y-2">
                          <Input
                            className="w-28"
                            type="number"
                            min={1}
                            value={editClientLimit}
                            onChange={(event) => setEditClientLimit(event.target.value)}
                            disabled={editUnlimitedClients}
                          />
                          <label className="flex items-center gap-2 text-xs text-neutral-700">
                            <input
                              type="checkbox"
                              className="h-4 w-4 rounded border-neutral-300 text-primary-600 focus:ring-primary-500"
                              checked={editUnlimitedClients}
                              onChange={(event) => setEditUnlimitedClients(event.target.checked)}
                            />
                            Unlimited clients
                          </label>
                        </div>
                      ) : (
                        <div>
                          <p>{organization.active_companies_count} active, {organization.companies_count} total</p>
                          <p className="text-xs text-neutral-500">
                            Limit: {organization.unlimited_clients ? 'Unlimited' : organization.client_limit}
                          </p>
                        </div>
                      )}
                    </TableCell>
                    <TableCell>{organization.users_count}</TableCell>
                    <TableCell>
                      <div className="space-y-2">
                        {organization.org_admins.length > 0 ? organization.org_admins.map((admin) => (
                          <div key={admin.id} className="flex items-center justify-between gap-2 text-sm">
                            <div className="min-w-0">
                              <p className="truncate font-medium text-neutral-800">
                                {admin.name}
                                {admin.active === false && <span className="ml-2 text-xs font-normal text-neutral-500">Inactive</span>}
                              </p>
                              <p className="truncate text-xs text-neutral-500">{admin.email}</p>
                            </div>
                            <div className="flex shrink-0 items-center gap-1">
                              <Button
                                size="sm"
                                variant="ghost"
                                className="h-8 w-8 p-0"
                                onClick={() => handleRenameAdmin(admin)}
                                disabled={adminActionId === admin.id}
                                title="Rename admin"
                              >
                                <Pencil className="h-4 w-4" />
                              </Button>
                              <Button
                                size="sm"
                                variant="ghost"
                                className="h-8 w-8 p-0"
                                onClick={() => handleToggleAdminActive(admin)}
                                disabled={adminActionId === admin.id}
                                title={admin.active === false ? 'Activate admin' : 'Deactivate admin'}
                              >
                                {admin.active === false ? <UserCheck className="h-4 w-4" /> : <UserX className="h-4 w-4" />}
                              </Button>
                              <Button
                                size="sm"
                                variant="ghost"
                                className="h-8 w-8 p-0 text-danger-600 hover:text-danger-700"
                                onClick={() => handleDeleteAdmin(admin)}
                                disabled={adminActionId === admin.id}
                                title="Delete admin"
                              >
                                <Trash2 className="h-4 w-4" />
                              </Button>
                            </div>
                          </div>
                        )) : (
                          <span className="text-sm text-danger-600">No org admins</span>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="text-right">
                      {editingId === organization.id ? (
                        <div className="flex justify-end gap-2">
                          <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                            {isSavingEdit ? 'Saving...' : 'Save'}
                          </Button>
                          <Button size="sm" variant="ghost" onClick={() => setEditingId(null)} disabled={isSavingEdit}>
                            Cancel
                          </Button>
                        </div>
                      ) : (
                        <div className="flex justify-end gap-2">
                          <Button size="sm" variant="outline" onClick={() => handleStartEdit(organization)}>Edit</Button>
                          <Button size="sm" variant="outline" onClick={() => handleStartAdmin(organization)}>Add Admin</Button>
                        </div>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {meta && meta.total_pages > 1 && (
              <div className="flex items-center justify-between border-t border-neutral-200 px-6 py-4">
                <p className="text-sm text-neutral-500">
                  Showing page {meta.current_page} of {meta.total_pages}
                </p>
                <div className="flex items-center gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={meta.current_page <= 1 || isLoading}
                    onClick={() => setPage((current) => Math.max(1, current - 1))}
                  >
                    Previous
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={meta.current_page >= meta.total_pages || isLoading}
                    onClick={() => setPage((current) => current + 1)}
                  >
                    Next
                  </Button>
                </div>
              </div>
            )}
          </Card>
        )}

        {adminOrgId && (
          <Card className="mt-6 p-5">
            <div className="mb-4 flex items-start justify-between gap-4">
              <div>
                <h3 className="text-sm font-semibold text-neutral-900">Add Organization Admin</h3>
                <p className="mt-1 text-xs text-neutral-500">
                  The new admin will be created under the organization&apos;s primary company.
                </p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => setAdminOrgId(null)} disabled={isSavingAdmin}>
                <X className="h-4 w-4" />
              </Button>
            </div>
            {adminError && (
              <div className="mb-4 rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-700">
                {adminError}
              </div>
            )}
            <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
              <Input placeholder="Admin email *" type="email" value={adminEmail} onChange={(event) => setAdminEmail(event.target.value)} />
              <Input placeholder="Admin name (optional)" value={adminName} onChange={(event) => setAdminName(event.target.value)} />
            </div>
            <div className="mt-4 flex gap-2">
              <Button onClick={handleCreateAdmin} disabled={isSavingAdmin}>
                {isSavingAdmin ? 'Creating...' : 'Create Admin'}
              </Button>
              <Button variant="ghost" onClick={() => setAdminOrgId(null)} disabled={isSavingAdmin}>Cancel</Button>
            </div>
          </Card>
        )}
      </div>
    </div>
  );
}
