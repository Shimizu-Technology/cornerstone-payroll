import { useState, useEffect, useCallback } from 'react';
import { Plus, Edit2, Building, Users, Check, X, AlertCircle } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { departmentsApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department } from '@/types';

// Fallback company ID for development when auth is disabled
const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);

interface DepartmentWithCount extends Department {
  employee_count: number;
}

export function Departments() {
  const { user } = useAuth();
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

  const fetchDepartments = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await departmentsApi.list({ company_id: companyId });
      setDepartments(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load departments');
    } finally {
      setIsLoading(false);
    }
  }, [companyId]);

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
      await departmentsApi.create({ name: newDeptName.trim(), company_id: companyId });
      setNewDeptName('');
      setIsAddingNew(false);
      fetchDepartments();
    } catch (err) {
      if (err instanceof ApiError && err.details?.name) {
        setNewDeptError(err.details.name[0]);
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
      await departmentsApi.update(editingId, { name: editName.trim() });
      setEditingId(null);
      setEditName('');
      fetchDepartments();
    } catch (err) {
      if (err instanceof ApiError && err.details?.name) {
        setEditError(err.details.name[0]);
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
    try {
      await departmentsApi.update(dept.id, { active: !dept.active });
      fetchDepartments();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to update department');
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

      <div className="p-6 lg:p-8">
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
            <div className="flex items-start gap-3">
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
          <Card>
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
                          >
                            {dept.active ? 'Deactivate' : 'Activate'}
                          </Button>
                        </div>
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
