import { useCallback, useEffect, useState } from 'react';
import { AlertCircle, Building2, Check, Mail, Plus, RefreshCw, ShieldCheck, X } from 'lucide-react';
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
import { ApiError, organizationsApi, type OrganizationSummary } from '@/services/api';

export function Organizations() {
  const [organizations, setOrganizations] = useState<OrganizationSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);

  const [isAdding, setIsAdding] = useState(false);
  const [isSavingNew, setIsSavingNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newSlug, setNewSlug] = useState('');
  const [newPrimaryCompanyName, setNewPrimaryCompanyName] = useState('');
  const [newAdminName, setNewAdminName] = useState('');
  const [newAdminEmail, setNewAdminEmail] = useState('');
  const [newError, setNewError] = useState<string | null>(null);

  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editSlug, setEditSlug] = useState('');
  const [editStatus, setEditStatus] = useState<'active' | 'inactive'>('active');
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);

  const [adminOrgId, setAdminOrgId] = useState<number | null>(null);
  const [adminName, setAdminName] = useState('');
  const [adminEmail, setAdminEmail] = useState('');
  const [adminError, setAdminError] = useState<string | null>(null);
  const [isSavingAdmin, setIsSavingAdmin] = useState(false);

  const fetchOrganizations = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await organizationsApi.list();
      setOrganizations(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load organizations');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchOrganizations();
  }, [fetchOrganizations]);

  useEffect(() => {
    if (!successMessage) return;
    const timer = setTimeout(() => setSuccessMessage(null), 6000);
    return () => clearTimeout(timer);
  }, [successMessage]);

  const resetNewForm = () => {
    setIsAdding(false);
    setNewName('');
    setNewSlug('');
    setNewPrimaryCompanyName('');
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

    setIsSavingNew(true);
    setNewError(null);
    try {
      const response = await organizationsApi.create({
        name: newName.trim(),
        slug: newSlug.trim() || undefined,
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
      await fetchOrganizations();
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
    setEditError(null);
  };

  const handleSaveEdit = async () => {
    if (!editingId || !editName.trim()) {
      setEditError('Organization name is required');
      return;
    }

    setIsSavingEdit(true);
    setEditError(null);
    try {
      await organizationsApi.update(editingId, {
        name: editName.trim(),
        slug: editSlug.trim(),
        status: editStatus,
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

  const activeCount = organizations.filter((org) => org.status === 'active').length;
  const totalCompanies = organizations.reduce((sum, org) => sum + org.companies_count, 0);
  const totalUsers = organizations.reduce((sum, org) => sum + org.users_count, 0);

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
                <p className="text-2xl font-semibold text-neutral-900">{organizations.length}</p>
              </div>
            </div>
          </Card>
          <Card className="p-4">
            <div className="flex items-center gap-3">
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-green-50 text-green-700">
                <Check className="h-5 w-5" />
              </div>
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Active</p>
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
                <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Clients / Users</p>
                <p className="text-2xl font-semibold text-neutral-900">{totalCompanies} / {totalUsers}</p>
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
          <Card>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Organization</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Clients</TableHead>
                  <TableHead>Users</TableHead>
                  <TableHead>Org Admins</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {organizations.map((organization) => (
                  <TableRow key={organization.id}>
                    <TableCell>
                      {editingId === organization.id ? (
                        <div className="space-y-2">
                          <Input value={editName} onChange={(event) => setEditName(event.target.value)} />
                          <Input value={editSlug} onChange={(event) => setEditSlug(event.target.value)} />
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
                    <TableCell>{organization.active_companies_count} active / {organization.companies_count} total</TableCell>
                    <TableCell>{organization.users_count}</TableCell>
                    <TableCell>
                      <div className="space-y-1">
                        {organization.org_admins.length > 0 ? organization.org_admins.map((admin) => (
                          <div key={admin.id} className="text-sm">
                            <span className="font-medium text-neutral-800">{admin.name}</span>
                            <span className="ml-1 text-neutral-500">{admin.email}</span>
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
