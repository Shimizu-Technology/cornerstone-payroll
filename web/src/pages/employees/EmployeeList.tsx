import { useState, useEffect, useCallback } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { 
  Plus, 
  Search, 
  ChevronLeft, 
  ChevronRight,
  Users
} from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
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
import {
  formatCurrency,
  employeeStatusConfig,
  employmentTypeLabels,
  getInitials,
} from '@/lib/utils';
import { employeesApi, departmentsApi } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Employee, Department, PaginationMeta } from '@/types';

// Fallback company ID for development when auth is disabled
const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);

export function EmployeeList() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { user } = useAuth();
  // Use company_id from auth context, fall back to env var for dev mode
  const companyId = user?.company_id ?? DEV_COMPANY_ID;
  
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [departments, setDepartments] = useState<(Department & { employee_count: number })[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Filters from URL params
  const search = searchParams.get('search') || '';
  const status = searchParams.get('status') || '';
  const departmentId = searchParams.get('department_id') || '';
  const page = parseInt(searchParams.get('page') || '1', 10);

  const fetchEmployees = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await employeesApi.list({
        company_id: companyId,
        search: search || undefined,
        status: status || undefined,
        department_id: departmentId ? parseInt(departmentId, 10) : undefined,
        page,
        per_page: 20,
      });
      setEmployees(response.data);
      setMeta(response.meta);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load employees');
    } finally {
      setIsLoading(false);
    }
  }, [companyId, search, status, departmentId, page]);

  const fetchDepartments = useCallback(async () => {
    try {
      const response = await departmentsApi.list({ company_id: companyId, active: true });
      setDepartments(response.data);
    } catch (err) {
      console.error('Failed to load departments:', err);
    }
  }, [companyId]);

  useEffect(() => {
    fetchEmployees();
    fetchDepartments();
  }, [fetchEmployees, fetchDepartments]);

  const updateFilter = (key: string, value: string): void => {
    const newParams = new URLSearchParams(searchParams);
    if (value) {
      newParams.set(key, value);
    } else {
      newParams.delete(key);
    }
    // Reset to page 1 when filters change
    if (key !== 'page') {
      newParams.delete('page');
    }
    setSearchParams(newParams);
  };

  const handleSearch = (value: string): void => {
    updateFilter('search', value);
  };

  return (
    <div>
      <Header
        title="Employees"
        description="Manage your company's employees"
        actions={
          <Button onClick={() => navigate('/employees/new')}>
            <Plus className="w-4 h-4 mr-2" />
            Add Employee
          </Button>
        }
      />

      <div className="p-6 lg:p-8">
        {/* Filters */}
        <div className="mb-6 flex flex-col sm:flex-row gap-4">
          <div className="relative flex-1 max-w-md">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <Input
              type="text"
              placeholder="Search employees..."
              value={search}
              onChange={(e) => handleSearch(e.target.value)}
              className="pl-10"
            />
          </div>
          
          <div className="flex gap-3">
            <Select
              value={status}
              onChange={(e) => updateFilter('status', e.target.value)}
              className="w-36"
            >
              <option value="">All Status</option>
              <option value="active">Active</option>
              <option value="inactive">Inactive</option>
              <option value="terminated">Terminated</option>
            </Select>

            <Select
              value={departmentId}
              onChange={(e) => updateFilter('department_id', e.target.value)}
              className="w-44"
            >
              <option value="">All Departments</option>
              {departments.map((dept) => (
                <option key={dept.id} value={dept.id}>
                  {dept.name} ({dept.employee_count})
                </option>
              ))}
            </Select>
          </div>
        </div>

        {/* Error State */}
        {error && (
          <div className="mb-6 p-4 bg-danger-50 border border-danger-200 rounded-lg text-danger-700">
            {error}
          </div>
        )}

        {/* Loading State */}
        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600" />
          </div>
        ) : employees.length === 0 ? (
          /* Empty State */
          <div className="text-center py-12">
            <Users className="mx-auto h-12 w-12 text-gray-400" />
            <h3 className="mt-2 text-sm font-medium text-gray-900">No employees found</h3>
            <p className="mt-1 text-sm text-gray-500">
              {search || status || departmentId
                ? 'Try adjusting your filters.'
                : 'Get started by adding your first employee.'}
            </p>
            {!search && !status && !departmentId && (
              <div className="mt-6">
                <Button onClick={() => navigate('/employees/new')}>
                  <Plus className="w-4 h-4 mr-2" />
                  Add Employee
                </Button>
              </div>
            )}
          </div>
        ) : (
          /* Employee Table */
          <>
            <Card>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead>Department</TableHead>
                    <TableHead>Type</TableHead>
                    <TableHead>Pay Rate</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {employees.map((employee) => {
                    const statusConfig = employeeStatusConfig[employee.status];
                    const deptName = departments.find(d => d.id === employee.department_id)?.name;
                    return (
                      <TableRow key={employee.id}>
                        <TableCell>
                          <div className="flex items-center gap-3">
                            <div className="w-10 h-10 bg-primary-100 rounded-full flex items-center justify-center">
                              <span className="text-primary-700 font-medium text-sm">
                                {getInitials(employee.first_name, employee.last_name)}
                              </span>
                            </div>
                            <div>
                              <p className="font-medium text-gray-900">
                                {employee.first_name} {employee.last_name}
                              </p>
                              {employee.email && (
                                <p className="text-sm text-gray-500">{employee.email}</p>
                              )}
                            </div>
                          </div>
                        </TableCell>
                        <TableCell>
                          <span className="text-sm text-gray-700">
                            {deptName || '—'}
                          </span>
                        </TableCell>
                        <TableCell>
                          <span className="text-sm text-gray-700">
                            {employmentTypeLabels[employee.employment_type]}
                          </span>
                        </TableCell>
                        <TableCell>
                          <span className="font-medium text-gray-900">
                            {employee.employment_type === 'hourly'
                              ? `${formatCurrency(employee.pay_rate)}/hr`
                              : `${formatCurrency(employee.pay_rate)}/yr`}
                          </span>
                        </TableCell>
                        <TableCell>
                          <Badge
                            variant={
                              employee.status === 'active' ? 'success' :
                              employee.status === 'inactive' ? 'default' :
                              'danger'
                            }
                          >
                            {statusConfig.label}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-right">
                          <Button 
                            variant="ghost" 
                            size="sm"
                            onClick={() => navigate(`/employees/${employee.id}`)}
                          >
                            Edit
                          </Button>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </Card>

            {/* Pagination */}
            {meta && meta.total_pages > 1 && (
              <div className="mt-4 flex items-center justify-between">
                <p className="text-sm text-gray-500">
                  Showing {((meta.current_page - 1) * meta.per_page) + 1} to{' '}
                  {Math.min(meta.current_page * meta.per_page, meta.total_count)} of{' '}
                  {meta.total_count} employees
                </p>
                <div className="flex gap-2">
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={meta.current_page === 1}
                    onClick={() => updateFilter('page', String(meta.current_page - 1))}
                  >
                    <ChevronLeft className="w-4 h-4" />
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={meta.current_page === meta.total_pages}
                    onClick={() => updateFilter('page', String(meta.current_page + 1))}
                  >
                    <ChevronRight className="w-4 h-4" />
                  </Button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
