import { useState, useEffect, useCallback, useMemo } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { 
  Plus, 
  Search, 
  ChevronLeft, 
  ChevronRight,
  ChevronDown,
  Users,
  Upload
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
import { EmployeeBulkImportModal } from '@/components/employees/EmployeeBulkImportModal';
import type { Employee, Department, PaginationMeta } from '@/types';

const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);

const TYPE_ORDER = ['salary', 'hourly', 'contractor'] as const;
const TYPE_COLORS: Record<string, string> = {
  salary: 'bg-purple-50 text-purple-700 border-purple-200',
  hourly: 'bg-blue-50 text-blue-700 border-blue-200',
  contractor: 'bg-amber-50 text-amber-700 border-amber-200',
};

export function EmployeeList() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { user } = useAuth();
  const companyId = user?.company_id ?? DEV_COMPANY_ID;
  
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [departments, setDepartments] = useState<(Department & { employee_count: number })[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showBulkImport, setShowBulkImport] = useState(false);
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(new Set());

  const search = searchParams.get('search') || '';
  const status = searchParams.get('status') ?? 'active';
  const departmentId = searchParams.get('department_id') || '';
  const employmentType = searchParams.get('employment_type') || '';
  const page = parseInt(searchParams.get('page') || '1', 10);

  const fetchEmployees = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const response = await employeesApi.list({
        company_id: companyId,
        search: search || undefined,
        status: status === 'all' ? undefined : (status || undefined),
        department_id: departmentId ? parseInt(departmentId, 10) : undefined,
        employment_type: employmentType || undefined,
        page,
        per_page: 500,
        group_by: 'employment_type',
      });
      setEmployees(response.data);
      setMeta(response.meta);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load employees');
    } finally {
      setIsLoading(false);
    }
  }, [companyId, search, status, departmentId, employmentType, page]);

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
    if (key !== 'page') {
      newParams.delete('page');
    }
    setSearchParams(newParams);
  };

  const handleSearch = (value: string): void => {
    updateFilter('search', value);
  };

  const toggleGroup = (type: string) => {
    setCollapsedGroups(prev => {
      const next = new Set(prev);
      if (next.has(type)) next.delete(type);
      else next.add(type);
      return next;
    });
  };

  const grouped = useMemo(() => {
    const groups: Record<string, Employee[]> = {};
    for (const emp of employees) {
      const type = emp.employment_type || 'hourly';
      if (!groups[type]) groups[type] = [];
      groups[type].push(emp);
    }
    return TYPE_ORDER
      .filter(t => groups[t]?.length)
      .map(t => ({ type: t, label: employmentTypeLabels[t] || t, employees: groups[t] }));
  }, [employees]);

  const hasActiveFilters = !!(search || departmentId || employmentType || status !== 'active');

  return (
    <div>
      <Header
        title="Employees"
        description="Manage your company's employees"
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={() => setShowBulkImport(true)}>
              <Upload className="w-4 h-4 mr-2" />
              Bulk Import
            </Button>
            <Button onClick={() => navigate('/employees/new')}>
              <Plus className="w-4 h-4 mr-2" />
              Add Employee
            </Button>
          </div>
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
          
          <div className="flex gap-3 flex-wrap">
            <Select
              value={status}
              onChange={(e) => updateFilter('status', e.target.value)}
              className="w-36"
            >
              <option value="active">Active</option>
              <option value="all">All Status</option>
              <option value="inactive">Inactive</option>
              <option value="terminated">Terminated</option>
            </Select>

            <Select
              value={employmentType}
              onChange={(e) => updateFilter('employment_type', e.target.value)}
              className="w-36"
            >
              <option value="">All Types</option>
              <option value="salary">Salary</option>
              <option value="hourly">Hourly</option>
              <option value="contractor">Contractor</option>
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
          <div className="text-center py-12">
            <Users className="mx-auto h-12 w-12 text-gray-400" />
            <h3 className="mt-2 text-sm font-medium text-gray-900">No employees found</h3>
            <p className="mt-1 text-sm text-gray-500">
              {hasActiveFilters
                ? 'Try adjusting your filters.'
                : 'Get started by adding your first employee.'}
            </p>
            {!hasActiveFilters && (
              <div className="mt-6">
                <Button onClick={() => navigate('/employees/new')}>
                  <Plus className="w-4 h-4 mr-2" />
                  Add Employee
                </Button>
              </div>
            )}
          </div>
        ) : (
          <>
            <div className="space-y-6">
              {grouped.map(({ type, label, employees: groupEmployees }) => {
                const isCollapsed = collapsedGroups.has(type);
                return (
                  <div key={type}>
                    <button
                      onClick={() => toggleGroup(type)}
                      className="flex items-center gap-2 mb-3 group cursor-pointer"
                    >
                      <ChevronDown className={`w-4 h-4 text-gray-400 transition-transform ${isCollapsed ? '-rotate-90' : ''}`} />
                      <h3 className="text-sm font-semibold text-gray-500 uppercase tracking-wider group-hover:text-gray-700">
                        {label}
                      </h3>
                      <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium border ${TYPE_COLORS[type] || 'bg-gray-50 text-gray-700 border-gray-200'}`}>
                        {groupEmployees.length}
                      </span>
                    </button>
                    {!isCollapsed && (
                      <Card>
                        <Table>
                          <TableHeader>
                            <TableRow>
                              <TableHead>Employee</TableHead>
                              <TableHead>Department</TableHead>
                              <TableHead>Pay Rate</TableHead>
                              <TableHead>Status</TableHead>
                              <TableHead className="text-right">Actions</TableHead>
                            </TableRow>
                          </TableHeader>
                          <TableBody>
                            {groupEmployees.map((employee) => (
                              <EmployeeTableRow
                                key={employee.id}
                                employee={employee}
                                departments={departments}
                                onEdit={() => navigate(`/employees/${employee.id}`)}
                              />
                            ))}
                          </TableBody>
                        </Table>
                      </Card>
                    )}
                  </div>
                );
              })}
            </div>

            {meta && (
              <div className="mt-4 flex items-center justify-between">
                <p className="text-sm text-gray-500">
                  {meta.total_count} employee{meta.total_count !== 1 ? 's' : ''} total
                </p>
                {meta.total_pages > 1 && (
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
                )}
              </div>
            )}
          </>
        )}
      </div>

      <EmployeeBulkImportModal
        open={showBulkImport}
        onClose={() => setShowBulkImport(false)}
        onComplete={() => { setShowBulkImport(false); fetchEmployees(); }}
      />
    </div>
  );
}

function EmployeeTableRow({
  employee,
  departments,
  onEdit,
}: {
  employee: Employee;
  departments: (Department & { employee_count: number })[];
  onEdit: () => void;
}) {
  const statusConfig = employeeStatusConfig[employee.status];
  const deptName = departments.find(d => d.id === employee.department_id)?.name;
  const activeWageRates = (employee.wage_rates || []).filter((rate) => rate.active !== false);
  const supportsHourlyMultiRate =
    employee.employment_type === 'hourly' ||
    (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly');
  const hasMultipleRates = supportsHourlyMultiRate && activeWageRates.length > 1;

  return (
    <TableRow>
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
        <div className="space-y-1">
          {hasMultipleRates ? (
            <div className="space-y-1">
              {activeWageRates.map((rate) => (
                <div key={`${employee.id}-${rate.label}`} className="text-xs">
                  <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                  <span className="text-gray-500">{formatCurrency(rate.rate)}/hr</span>
                </div>
              ))}
            </div>
          ) : (
            <span className="font-medium text-gray-900">
              {employee.employment_type === 'salary' && (employee.salary_type === 'variable' || employee.pay_rate === 0)
                ? 'Variable'
                : employee.employment_type === 'hourly'
                ? `${formatCurrency(employee.pay_rate)}/hr`
                : employee.employment_type === 'contractor'
                ? employee.contractor_pay_type === 'hourly'
                  ? `${formatCurrency(employee.pay_rate)}/hr`
                  : `${formatCurrency(employee.pay_rate)}/period`
                : employee.salary_type === 'per_period'
                ? `${formatCurrency(employee.pay_rate)}/period`
                : `${formatCurrency(employee.pay_rate)}/yr`}
            </span>
          )}
          {hasMultipleRates && (
            <p className="text-xs text-gray-500">
              {activeWageRates.length} hourly rates configured
            </p>
          )}
        </div>
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
          onClick={onEdit}
        >
          Edit
        </Button>
      </TableCell>
    </TableRow>
  );
}
