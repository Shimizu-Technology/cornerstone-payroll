import { useState, useEffect, useCallback } from 'react';
import { Plus, Edit2, Building, Users, Check, X, AlertCircle } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Input } from '@/components/ui/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { departmentsApi, clientDepartmentsApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department } from '@/types';

// Fallback company ID for development when auth is disabled
const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);

interface DepartmentWithCount extends Department {
  employee_count: number;
}

export function Departments() {
  const { user, isClient } = useAuth();
  // Use company_id from auth context, fall back to env var for dev mode
  const companyId = user?.company_id ?? DEV_COMPANY_ID;

  const [departments, setDepartments] = useState<DepartmentWithCount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  
  // New department form
  const [isAddingNew, setIsAddingNew] = useState(false);
  const [newDeptName, setNewDeptName] = useState('');
  const [newDeptError, setNewDeptError] = useState<string | null>(null);
  const [isSavingNew, setIsSavingNew] = useState(false);
  
  // Edit state
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState('');
  const [editError, setEditError] = useState<string | null>(null);
  const [isSavingEdit, setIsSavingEdit] = useState(false);
  const [togglingId, setTogglingId] = useState<number | null>(null);

  const fetchDepartments = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = isClient
        ? await clientDepartmentsApi.list()
        : await departmentsApi.list({ company_id: companyId });
      setDepartments(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load departments');
    } finally {
      setIsLoading(false);
    }
  }, [companyId, isClient]);

  useEffect(() => {
    fetchDepartments();
  }, [fetchDepartments]);

  const handleAddNew = async (): Promise<void> => {
    if (!newDeptName.trim()) {
      setNewDeptError('Department name is required');
      return;
    }

    setIsSavingNew(true);
    setNewDeptError(null);

    try {
      if (isClient) {
        await clientDepartmentsApi.create({ name: newDeptName.trim() });
      } else {
        await departmentsApi.create({ name: newDeptName.trim(), company_id: companyId });
      }
      setNewDeptName('');
      setIsAddingNew(false);
      fetchDepartments();
    } catch (err) {
      if (err instanceof ApiError && err.fieldErrors.name) {
        setNewDeptError(err.fieldErrors.name[0]);
      } else {
        setNewDeptError(err instanceof Error ? err.message : 'Failed to create department');
      }
    } finally {
      setIsSavingNew(false);
    }
  };

  const handleCancelAdd = (): void => {
    setIsAddingNew(false);
    setNewDeptName('');
    setNewDeptError(null);
  };

  const handleStartEdit = (dept: DepartmentWithCount): void => {
    setEditingId(dept.id);
    setEditName(dept.name);
    setEditError(null);
  };

  const handleSaveEdit = async (): Promise<void> => {
    if (!editingId || !editName.trim()) {
      setEditError('Department name is required');
      return;
    }

    setIsSavingEdit(true);
    setEditError(null);

    try {
      if (isClient) {
        await clientDepartmentsApi.update(editingId, { name: editName.trim() });
      } else {
        await departmentsApi.update(editingId, { name: editName.trim() });
      }
      setEditingId(null);
      setEditName('');
      fetchDepartments();
    } catch (err) {
      if (err instanceof ApiError && err.fieldErrors.name) {
        setEditError(err.fieldErrors.name[0]);
      } else {
        setEditError(err instanceof Error ? err.message : 'Failed to update department');
      }
    } finally {
      setIsSavingEdit(false);
    }
  };

  const handleCancelEdit = (): void => {
    setEditingId(null);
    setEditName('');
    setEditError(null);
  };

  const handleToggleActive = async (dept: DepartmentWithCount): Promise<void> => {
    setTogglingId(dept.id);
    try {
      if (isClient) {
        await clientDepartmentsApi.update(dept.id, { active: !dept.active });
      } else {
        await departmentsApi.update(dept.id, { active: !dept.active });
      }
      fetchDepartments();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update department');
    } finally {
      setTogglingId(null);
    }
  };

  return (
    <div>
      <Header
        title="Departments"
        description="Manage your company's departments"
        actions={
          !isAddingNew && (
            <Button onClick={() => setIsAddingNew(true)}>
              <Plus className="w-4 h-4 mr-2" />
              Add Department
            </Button>
          )
        }
      />

      <div className="p-4 sm:p-6 lg:p-8">
        {/* Error State */}
        {error && (
          <div className="mb-6 p-4 bg-danger-50 border border-danger-200 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-danger-600 flex-shrink-0 mt-0.5" />
            <p className="text-danger-700">{error}</p>
          </div>
        )}

        {/* New Department Form */}
        {isAddingNew && (
          <Card className="mb-6 p-4">
            <h3 className="text-sm font-medium text-gray-900 mb-3">Add New Department</h3>
            <div className="flex flex-col items-stretch gap-3 sm:flex-row sm:items-start">
              <div className="flex-1">
                <Input
                  placeholder="Department name"
                  value={newDeptName}
                  onChange={(e) => {
                    setNewDeptName(e.target.value);
                    setNewDeptError(null);
                  }}
                  error={newDeptError || undefined}
                  autoFocus
                />
              </div>
              <Button
                size="sm"
                onClick={handleAddNew}
                disabled={isSavingNew}
              >
                <Check className="w-4 h-4 mr-1" />
                {isSavingNew ? 'Saving...' : 'Save'}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={handleCancelAdd}
                disabled={isSavingNew}
              >
                <X className="w-4 h-4" />
              </Button>
            </div>
          </Card>
        )}

        {/* Loading State */}
        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600" />
          </div>
        ) : departments.length === 0 ? (
          /* Empty State */
          <div className="text-center py-12">
            <Building className="mx-auto h-12 w-12 text-gray-400" />
            <h3 className="mt-2 text-sm font-medium text-gray-900">No departments</h3>
            <p className="mt-1 text-sm text-gray-500">
              Get started by creating your first department.
            </p>
            {!isAddingNew && (
              <div className="mt-6">
                <Button onClick={() => setIsAddingNew(true)}>
                  <Plus className="w-4 h-4 mr-2" />
                  Add Department
                </Button>
              </div>
            )}
          </div>
        ) : (
          /* Departments Table */
          <>
            <div className="space-y-3 sm:hidden">
              {departments.map((dept) => (
                <MobileRecordCard key={dept.id}>
                  {editingId === dept.id ? (
                    <div className="space-y-3">
                      <Input
                        value={editName}
                        onChange={(e) => {
                          setEditName(e.target.value);
                          setEditError(null);
                        }}
                        error={editError || undefined}
                        autoFocus
                      />
                      <MobileCardActions className="mt-0 grid grid-cols-2">
                        <Button size="sm" onClick={handleSaveEdit} disabled={isSavingEdit}>
                          <Check className="mr-1 h-4 w-4" />
                          Save
                        </Button>
                        <Button variant="outline" size="sm" onClick={handleCancelEdit} disabled={isSavingEdit}>
                          Cancel
                        </Button>
                      </MobileCardActions>
                    </div>
                  ) : (
                    <>
                      <div className="flex items-start gap-3">
                        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-100 text-primary-700">
                          <Building className="h-5 w-5" />
                        </div>
                        <div className="min-w-0 flex-1">
                          <div className="flex items-start justify-between gap-3">
                            <p className="font-semibold text-neutral-950">{dept.name}</p>
                            <Badge variant={dept.active ? 'success' : 'default'}>{dept.active ? 'Active' : 'Inactive'}</Badge>
                          </div>
                          <div className="mt-4 grid grid-cols-2 gap-3">
                            <MobileField label="Employees" value={dept.employee_count} />
                            <MobileField label="Status" value={dept.active ? 'Active' : 'Inactive'} />
                          </div>
                          <MobileCardActions>
                            <Button variant="outline" size="sm" onClick={() => handleStartEdit(dept)}>
                              <Edit2 className="mr-1 h-4 w-4" />
                              Edit
                            </Button>
                            <Button variant="ghost" size="sm" onClick={() => handleToggleActive(dept)} disabled={togglingId === dept.id}>
                              {dept.active ? 'Deactivate' : 'Activate'}
                            </Button>
                          </MobileCardActions>
                        </div>
                      </div>
                    </>
                  )}
                </MobileRecordCard>
              ))}
            </div>
            <Card className="hidden sm:block">
              <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Department</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {departments.map((dept) => (
                  <TableRow key={dept.id}>
                    <TableCell>
                      {editingId === dept.id ? (
                        <div className="flex items-center gap-2">
                          <Input
                            value={editName}
                            onChange={(e) => {
                              setEditName(e.target.value);
                              setEditError(null);
                            }}
                            error={editError || undefined}
                            className="max-w-xs"
                            autoFocus
                          />
                          <Button
                            size="sm"
                            onClick={handleSaveEdit}
                            disabled={isSavingEdit}
                          >
                            <Check className="w-4 h-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={handleCancelEdit}
                            disabled={isSavingEdit}
                          >
                            <X className="w-4 h-4" />
                          </Button>
                        </div>
                      ) : (
                        <div className="flex items-center gap-3">
                          <div className="w-10 h-10 bg-primary-100 rounded-lg flex items-center justify-center">
                            <Building className="w-5 h-5 text-primary-700" />
                          </div>
                          <span className="font-medium text-gray-900">{dept.name}</span>
                        </div>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex items-center gap-2 text-gray-600">
                        <Users className="w-4 h-4" />
                        <span>{dept.employee_count}</span>
                      </div>
                    </TableCell>
                    <TableCell>
                      <Badge variant={dept.active ? 'success' : 'default'}>
                        {dept.active ? 'Active' : 'Inactive'}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      {editingId !== dept.id && (
                        <div className="flex items-center justify-end gap-2">
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => handleStartEdit(dept)}
                          >
                            <Edit2 className="w-4 h-4 mr-1" />
                            Edit
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => handleToggleActive(dept)}
                            disabled={togglingId === dept.id}
                          >
                            {togglingId === dept.id ? (
                              <span className="flex items-center gap-1">
                                <div className="w-3 h-3 animate-spin rounded-full border-2 border-gray-300 border-t-gray-600" />
                                {dept.active ? 'Deactivating...' : 'Activating...'}
                              </span>
                            ) : dept.active ? 'Deactivate' : 'Activate'}
                          </Button>
                        </div>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
              </Table>
            </Card>
          </>
        )}
      </div>
    </div>
  );
}
