import { useEffect, useState, useCallback, useMemo } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { AlertCircle, Search } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { comparePayPeriodsByPeriod, formatCurrency, formatDateRange, formatGuamDateTimeShort, payPeriodStatusConfig } from '@/lib/utils';
import { useCompany } from '@/contexts/CompanyContext';
import { companiesApi, payPeriodsApi } from '@/services/api';
import type { PayPeriod } from '@/types';

function PayPeriodMobileCard({
  period,
  actionInFlight,
  onView,
  onEdit,
  onDelete,
  onRun,
  onApprove,
  onCommit,
}: {
  period: PayPeriod;
  actionInFlight: string | null;
  onView: () => void;
  onEdit: () => void;
  onDelete: () => void;
  onRun: () => void;
  onApprove: () => void;
  onCommit: () => void;
}) {
  const statusConfig = payPeriodStatusConfig[period.status];

  return (
    <MobileRecordCard>
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-semibold text-neutral-950">{formatDateRange(period.start_date, period.end_date)}</p>
          <p className="mt-1 text-sm text-neutral-500">
            Pay date {new Date(period.pay_date).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })}
          </p>
        </div>
        <Badge
          variant={
            period.correction_status === 'voided' ? 'danger' :
              period.status === 'committed' ? 'success' :
                period.status === 'approved' ? 'info' :
                  period.status === 'calculated' ? 'warning' : 'default'
          }
        >
          {period.correction_status === 'voided' ? 'Voided' : (statusConfig?.label || period.status)}
        </Badge>
      </div>
      <div className="mt-4 grid grid-cols-2 gap-3">
        <MobileField label="Employees" value={period.employee_count || 0} />
        <MobileField label="Gross" value={period.total_gross ? formatCurrency(period.total_gross) : '—'} />
        <MobileField label="Net" value={period.total_net ? formatCurrency(period.total_net) : '—'} />
        <MobileField
          label="Processed"
          value={period.processed_at ? formatGuamDateTimeShort(period.processed_at) : 'Not processed'}
        />
      </div>
      <MobileCardActions>
        <Button variant="outline" size="sm" onClick={onView}>View</Button>
        {period.status !== 'committed' && (
          <>
            <Button variant="ghost" size="sm" onClick={onEdit}>Edit</Button>
            <Button variant="ghost" size="sm" className="text-danger-700" onClick={onDelete} disabled={actionInFlight !== null}>Delete</Button>
          </>
        )}
        {period.status === 'draft' && <Button size="sm" onClick={onView}>Enter hours</Button>}
        {period.status === 'calculated' && (
          <>
            <Button variant="outline" size="sm" onClick={onRun} disabled={actionInFlight !== null}>Recalculate</Button>
            <Button size="sm" onClick={onApprove} disabled={actionInFlight !== null}>Approve</Button>
          </>
        )}
        {period.status === 'approved' && <Button size="sm" onClick={onCommit} disabled={actionInFlight !== null}>Commit</Button>}
      </MobileCardActions>
    </MobileRecordCard>
  );
}

export function PayPeriods() {
  const location = useLocation();
  const navigate = useNavigate();
  const { activeCompanyId } = useCompany();
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [switchNotice, setSwitchNotice] = useState<string | null>(() => {
    const state = location.state as { companySwitchNotice?: string } | null;
    return state?.companySwitchNotice ?? null;
  });
  const [statusFilter, setStatusFilter] = useState<string | undefined>();
  const [statusCounts, setStatusCounts] = useState<Record<string, number>>({});
  const [searchTerm, setSearchTerm] = useState('');
  const [sortBy, setSortBy] = useState<
    'pay_period' | 'pay_date' | 'processed' | 'employees' | 'gross' | 'net' | 'status'
  >('pay_period');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');
  
  // Modal state
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isEditOpen, setIsEditOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isEditSubmitting, setIsEditSubmitting] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const [currentNextCheckNumber, setCurrentNextCheckNumber] = useState<number | null>(null);
  const [loadingCheckSettings, setLoadingCheckSettings] = useState(false);
  const [checkSettingsError, setCheckSettingsError] = useState<string | null>(null);
  const [actionInFlight, setActionInFlight] = useState<string | null>(null);
  const [editingPayPeriod, setEditingPayPeriod] = useState<PayPeriod | null>(null);
  const [formData, setFormData] = useState({
    start_date: '',
    end_date: '',
    pay_date: '',
    starting_check_number: '',
    notes: '',
  });
  const [editFormData, setEditFormData] = useState({
    start_date: '',
    end_date: '',
    pay_date: '',
    notes: '',
  });

  // Load pay periods
  const loadPayPeriods = useCallback(async (silent = false) => {
    try {
      if (!silent) setLoading(true);
      setError(null);
      const response = await payPeriodsApi.list({ status: statusFilter });
      setPayPeriods(response.pay_periods);
      setStatusCounts(response.meta.statuses);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay periods');
    } finally {
      if (!silent) setLoading(false);
    }
  }, [statusFilter]);

  useEffect(() => {
    loadPayPeriods();
  }, [loadPayPeriods]);

  useEffect(() => {
    const state = location.state as { companySwitchNotice?: string } | null;
    if (!state?.companySwitchNotice) return;

    setSwitchNotice(state.companySwitchNotice);
    navigate('.', { replace: true, state: null });
  }, [location.state, navigate]);

  useEffect(() => {
    if (!switchNotice) return;

    const timer = window.setTimeout(() => {
      setSwitchNotice(null);
    }, 6000);

    return () => window.clearTimeout(timer);
  }, [switchNotice]);

  const handleCreate = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const startingCheckNumber = formData.starting_check_number.trim();

    if (formData.end_date <= formData.start_date) {
      setCreateError('End date must be after start date');
      return;
    }
    if (formData.pay_date < formData.end_date) {
      setCreateError('Pay date must be on or after end date');
      return;
    }
    if (startingCheckNumber && !/^\d+$/.test(startingCheckNumber)) {
      setCreateError('Starting check number must be numeric.');
      return;
    }

    try {
      setIsSubmitting(true);
      setCreateError(null);
      setError(null);
      await payPeriodsApi.create({
        ...formData,
        starting_check_number: startingCheckNumber,
      });
      setIsCreateOpen(false);
      setCurrentNextCheckNumber(null);
      setFormData({ start_date: '', end_date: '', pay_date: '', starting_check_number: '', notes: '' });
      loadPayPeriods(true);
    } catch (err) {
      setCreateError(err instanceof Error ? err.message : 'Failed to create pay period');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleRunPayroll = async (id: number) => {
    try {
      setActionInFlight(`run-${id}`);
      setError(null);
      await payPeriodsApi.runPayroll(id);
      loadPayPeriods(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      setActionInFlight(null);
    }
  };

  const openEditModal = (period: PayPeriod) => {
    setEditingPayPeriod(period);
    setEditError(null);
    setError(null);
    setEditFormData({
      start_date: period.start_date,
      end_date: period.end_date,
      pay_date: period.pay_date,
      notes: period.notes || '',
    });
    setIsEditOpen(true);
  };

  const handleEdit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!editingPayPeriod) return;

    if (editFormData.end_date <= editFormData.start_date) {
      setEditError('End date must be after start date');
      return;
    }
    if (editFormData.pay_date < editFormData.end_date) {
      setEditError('Pay date must be on or after end date');
      return;
    }

    if (
      editingPayPeriod.status !== 'draft' &&
      (editFormData.start_date !== editingPayPeriod.start_date ||
        editFormData.end_date !== editingPayPeriod.end_date ||
        editFormData.pay_date !== editingPayPeriod.pay_date) &&
      !window.confirm('Changing payroll dates affects tax year, YTD, checks, and reports. This pay period will be moved back to draft and must be recalculated before approval/commit. Continue?')
    ) {
      return;
    }

    try {
      setIsEditSubmitting(true);
      setEditError(null);
      setError(null);
      await payPeriodsApi.update(editingPayPeriod.id, editFormData);
      setIsEditOpen(false);
      setEditingPayPeriod(null);
      loadPayPeriods(true);
    } catch (err) {
      setEditError(err instanceof Error ? err.message : 'Failed to update pay period');
    } finally {
      setIsEditSubmitting(false);
    }
  };

  const handleApprove = async (id: number) => {
    try {
      setActionInFlight(`approve-${id}`);
      setError(null);
      await payPeriodsApi.approve(id);
      loadPayPeriods(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to approve pay period');
    } finally {
      setActionInFlight(null);
    }
  };

  const handleCommit = async (id: number) => {
    if (!confirm('Are you sure you want to commit this pay period? This action cannot be undone.')) {
      return;
    }
    try {
      setActionInFlight(`commit-${id}`);
      setError(null);
      await payPeriodsApi.commit(id);
      loadPayPeriods(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to commit pay period');
    } finally {
      setActionInFlight(null);
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Are you sure you want to delete this pay period?')) {
      return;
    }
    try {
      setActionInFlight(`delete-${id}`);
      setError(null);
      await payPeriodsApi.delete(id);
      setPayPeriods((prev) => prev.filter((period) => period.id !== id));
      loadPayPeriods(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete pay period');
    } finally {
      setActionInFlight(null);
    }
  };

  // Generate default dates for new pay period (biweekly)
  const setDefaultDates = () => {
    const today = new Date();
    const startDate = new Date(today);
    startDate.setDate(today.getDate() - today.getDay() + 1); // Start of this week (Monday)
    
    const endDate = new Date(startDate);
    endDate.setDate(startDate.getDate() + 13); // 2 weeks
    
    const payDate = new Date(endDate);
    payDate.setDate(endDate.getDate() + 3); // 3 days after end
    
    setFormData({
      start_date: startDate.toISOString().split('T')[0],
      end_date: endDate.toISOString().split('T')[0],
      pay_date: payDate.toISOString().split('T')[0],
      starting_check_number: '',
      notes: '',
    });
  };

  const loadCurrentNextCheckNumber = async () => {
    if (!activeCompanyId) {
      setCurrentNextCheckNumber(null);
      setCheckSettingsError(null);
      setLoadingCheckSettings(false);
      return;
    }

    try {
      setLoadingCheckSettings(true);
      setCheckSettingsError(null);
      const response = await companiesApi.get(activeCompanyId);
      setCurrentNextCheckNumber(response.company.next_check_number ?? null);
    } catch (err) {
      setCurrentNextCheckNumber(null);
      const message = err instanceof Error ? err.message : 'Unable to load current check settings.';
      setCheckSettingsError(message);
    } finally {
      setLoadingCheckSettings(false);
    }
  };

  const openCreateModal = () => {
    setDefaultDates();
    setCreateError(null);
    setError(null);
    setCurrentNextCheckNumber(null);
    setCheckSettingsError(null);
    setIsCreateOpen(true);
    void loadCurrentNextCheckNumber();
  };

  const handleCreateOpenChange = (open: boolean) => {
    setIsCreateOpen(open);
    if (!open) {
      setCreateError(null);
      setCurrentNextCheckNumber(null);
      setCheckSettingsError(null);
      setLoadingCheckSettings(false);
    }
  };

  const handleEditOpenChange = (open: boolean) => {
    setIsEditOpen(open);
    if (!open) {
      setEditError(null);
      setEditingPayPeriod(null);
    }
  };

  const visiblePayPeriods = useMemo(() => {
    const normalizedSearch = searchTerm.trim().toLowerCase();
    const filtered = normalizedSearch
      ? payPeriods.filter((period) => {
          const haystack = [
            formatDateRange(period.start_date, period.end_date),
            new Date(period.pay_date).toLocaleDateString('en-US'),
            period.status,
            payPeriodStatusConfig[period.status]?.label,
            period.processed_by_name,
            period.processed_at ? formatGuamDateTimeShort(period.processed_at) : '',
          ]
            .filter(Boolean)
            .join(' ')
            .toLowerCase();

          return haystack.includes(normalizedSearch);
        })
      : payPeriods;

    const directionMultiplier = sortDirection === 'asc' ? 1 : -1;
    return [...filtered].sort((left, right) => {
      const compareStrings = (a: string, b: string) => a.localeCompare(b) * directionMultiplier;
      const compareNumbers = (a: number, b: number) => (a - b) * directionMultiplier;

      switch (sortBy) {
      case 'pay_period':
        return comparePayPeriodsByPeriod(left, right, sortDirection);
      case 'employees':
        return compareNumbers(left.employee_count || 0, right.employee_count || 0);
      case 'gross':
        return compareNumbers(left.total_gross || 0, right.total_gross || 0);
      case 'net':
        return compareNumbers(left.total_net || 0, right.total_net || 0);
      case 'status':
        return compareStrings(
          payPeriodStatusConfig[left.status]?.label || left.status,
          payPeriodStatusConfig[right.status]?.label || right.status
        );
      case 'processed':
        return compareNumbers(
          left.processed_at ? new Date(left.processed_at).getTime() : 0,
          right.processed_at ? new Date(right.processed_at).getTime() : 0
        );
      case 'pay_date':
      default:
        return compareNumbers(
          new Date(left.pay_date).getTime(),
          new Date(right.pay_date).getTime()
        ) || compareNumbers(
          new Date(left.end_date).getTime(),
          new Date(right.end_date).getTime()
        ) || compareNumbers(
          new Date(left.start_date).getTime(),
          new Date(right.start_date).getTime()
        ) || compareNumbers(left.id, right.id);
      }
    });
  }, [payPeriods, searchTerm, sortBy, sortDirection]);

  return (
    <div>
      <Header
        title="Pay Periods"
        description="Manage payroll periods and processing"
        actions={
          <Button onClick={openCreateModal}>
            New Pay Period
          </Button>
        }
      />

      <div className="p-4 sm:p-6 lg:p-8">
        {/* Error display */}
        {error && (
          <div className="mb-4 p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}
        {switchNotice && (
          <div
            role="status"
            className="mb-4 flex items-start justify-between gap-3 rounded-lg border border-primary-200 bg-primary-50 p-4 text-primary-800"
          >
            <span>{switchNotice}</span>
            <button
              type="button"
              onClick={() => setSwitchNotice(null)}
              className="shrink-0 rounded-md px-2 py-1 text-sm font-medium text-primary-700 transition-colors hover:bg-primary-100 hover:text-primary-900"
              aria-label="Dismiss company switch notice"
            >
              Dismiss
            </button>
          </div>
        )}

        {/* Status filter tabs */}
        <div className="mb-4 flex gap-2 overflow-x-auto pb-1 sm:flex-wrap">
          <Button
            variant={statusFilter === undefined ? 'primary' : 'outline'}
            size="sm"
            onClick={() => setStatusFilter(undefined)}
          >
            All ({Object.values(statusCounts).reduce((a, b) => a + b, 0)})
          </Button>
          {(['draft', 'calculated', 'approved', 'committed'] as const).map((status) => (
            <Button
              key={status}
              variant={statusFilter === status ? 'primary' : 'outline'}
              size="sm"
              onClick={() => setStatusFilter(status)}
            >
              {payPeriodStatusConfig[status]?.label || status} ({statusCounts[status] || 0})
            </Button>
          ))}
        </div>

        <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="relative w-full max-w-md">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
            <Input
              placeholder="Search pay periods..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="pl-10"
            />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap">
            <Select
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value as typeof sortBy)}
              className="w-full sm:w-44"
            >
              <option value="pay_period">Sort: Pay Period</option>
              <option value="pay_date">Sort: Pay Date</option>
              <option value="processed">Sort: Processed</option>
              <option value="employees">Sort: Employees</option>
              <option value="gross">Sort: Gross Pay</option>
              <option value="net">Sort: Net Pay</option>
              <option value="status">Sort: Status</option>
            </Select>
            <Select
              value={sortDirection}
              onChange={(e) => setSortDirection(e.target.value as typeof sortDirection)}
              className="w-full sm:w-32"
            >
              <option value="asc">Oldest / Low</option>
              <option value="desc">Newest / High</option>
            </Select>
          </div>
        </div>

        {/* Pay Period Table */}
        <Card>
          {loading ? (
            <div className="p-8 text-center text-gray-500">Loading...</div>
          ) : visiblePayPeriods.length === 0 ? (
            <div className="p-8 text-center text-gray-500">
              {searchTerm ? 'No pay periods match the current filters.' : 'No pay periods found. Create your first pay period to get started.'}
            </div>
          ) : (
            <>
              <div className="space-y-3 p-3 sm:hidden">
                {visiblePayPeriods.map((period) => (
                  <PayPeriodMobileCard
                    key={period.id}
                    period={period}
                    actionInFlight={actionInFlight}
                    onView={() => navigate(`/pay-periods/${period.id}`)}
                    onEdit={() => openEditModal(period)}
                    onDelete={() => handleDelete(period.id)}
                    onRun={() => handleRunPayroll(period.id)}
                    onApprove={() => handleApprove(period.id)}
                    onCommit={() => handleCommit(period.id)}
                  />
                ))}
              </div>
              <div className="hidden sm:block">
                <Table stickyHeader containerClassName="max-h-[32rem]">
                  <TableHeader>
                <TableRow>
                  <TableHead stickyLeft className="w-[240px] min-w-[240px] bg-gray-50">Pay Period</TableHead>
                  <TableHead>Pay Date</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Gross Pay</TableHead>
                  <TableHead>Net Pay</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Processed</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {visiblePayPeriods.map((period, index) => {
                  const statusConfig = payPeriodStatusConfig[period.status];
                  const rowTone = index % 2 === 0 ? 'bg-white' : 'bg-slate-100';
                  return (
                    <TableRow key={period.id} className={rowTone}>
                      <TableCell stickyLeft className={`w-[240px] min-w-[240px] ${rowTone}`}>
                        <span className="font-medium text-gray-900">
                          {formatDateRange(period.start_date, period.end_date)}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="text-sm text-gray-700">
                          {new Date(period.pay_date).toLocaleDateString('en-US', {
                            weekday: 'short',
                            month: 'short',
                            day: 'numeric',
                          })}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="text-sm text-gray-700">
                          {period.employee_count || 0}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="font-medium text-gray-900">
                          {period.total_gross ? formatCurrency(period.total_gross) : '—'}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="font-medium text-gray-900">
                          {period.total_net ? formatCurrency(period.total_net) : '—'}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <div className="flex flex-col gap-1 items-start">
                          <Badge
                            variant={
                              period.correction_status === 'voided' ? 'danger' :
                              period.status === 'committed' ? 'success' :
                              period.status === 'approved' ? 'info' :
                              period.status === 'calculated' ? 'warning' :
                              'default'
                            }
                          >
                            {period.correction_status === 'voided' ? 'Voided' : (statusConfig?.label || period.status)}
                          </Badge>
                          {period.correction_status === 'correction' && (
                            <Badge variant="warning">Correction</Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell className={rowTone}>
                        {period.processed_at ? (
                          <div className="text-sm">
                            <p className="font-medium text-gray-900">
                              {formatGuamDateTimeShort(period.processed_at)}
                            </p>
                            <p className="text-xs text-gray-500">
                              {period.processed_by_name ? `by ${period.processed_by_name}` : 'Operator not recorded'}
                            </p>
                          </div>
                        ) : (
                          <span className="text-sm text-gray-400">Not processed</span>
                        )}
                      </TableCell>
                      <TableCell className={`text-right ${rowTone}`}>
                        <div className="flex items-center justify-end gap-3">
                          <div className="flex items-center gap-1 text-sm">
                            <button
                              className="text-gray-500 hover:text-gray-800 hover:underline"
                              onClick={() => navigate(`/pay-periods/${period.id}`)}
                            >
                              View
                            </button>
                            {period.status !== 'committed' && (
                              <>
                                <span className="text-gray-300">·</span>
                                <button
                                  className="text-gray-500 hover:text-gray-800 hover:underline"
                                  onClick={() => openEditModal(period)}
                                >
                                  Edit
                                </button>
                                <span className="text-gray-300">·</span>
                                <button
                                  className="text-red-400 hover:text-red-600 hover:underline"
                                  onClick={() => handleDelete(period.id)}
                                  disabled={actionInFlight !== null}
                                >
                                  Delete
                                </button>
                              </>
                            )}
                          </div>

                          {period.status === 'draft' && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => navigate(`/pay-periods/${period.id}`)}
                            >
                              Enter Hours
                            </Button>
                          )}
                          {period.status === 'calculated' && (
                            <div className="flex items-center gap-1.5">
                              <Button
                                variant="outline"
                                size="sm"
                                onClick={() => handleRunPayroll(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Recalculate
                              </Button>
                              <Button
                                size="sm"
                                onClick={() => handleApprove(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Approve
                              </Button>
                            </div>
                          )}
                          {period.status === 'approved' && (
                            <Button
                              size="sm"
                              variant="primary"
                              onClick={() => handleCommit(period.id)}
                              disabled={actionInFlight !== null}
                            >
                              Commit
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
                  </TableBody>
                </Table>
              </div>
            </>
          )}
        </Card>

        {/* Workflow explanation */}
        <Card className="mt-8">
          <div className="p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Payroll Workflow</h3>
            <div className="grid gap-4 sm:flex sm:items-center sm:justify-between">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-gray-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-gray-600">1</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Draft</p>
                  <p className="text-sm text-gray-500">Create pay period</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-yellow-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-yellow-600">2</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Calculated</p>
                  <p className="text-sm text-gray-500">Review totals</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-blue-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-blue-600">3</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Approved</p>
                  <p className="text-sm text-gray-500">Ready to commit</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-green-600">4</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Committed</p>
                  <p className="text-sm text-gray-500">Locked & finalized</p>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </div>

      {/* Create Pay Period Modal */}
      <Dialog open={isCreateOpen} onOpenChange={handleCreateOpenChange}>
        <DialogContent>
          <form onSubmit={handleCreate}>
            <DialogHeader>
              <DialogTitle>New Pay Period</DialogTitle>
              <DialogDescription>
                Create a new pay period. Default dates are set for a biweekly schedule.
              </DialogDescription>
            </DialogHeader>
            {createError && (
              <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                <div className="flex gap-2">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <p>{createError}</p>
                </div>
              </div>
            )}
            <div className="grid gap-4 py-4">
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="start_date">Start Date</Label>
                  <Input
                    id="start_date"
                    type="date"
                    value={formData.start_date}
                    onChange={(e) => setFormData({ ...formData, start_date: e.target.value })}
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="end_date">End Date</Label>
                  <Input
                    id="end_date"
                    type="date"
                    value={formData.end_date}
                    onChange={(e) => setFormData({ ...formData, end_date: e.target.value })}
                    required
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="pay_date">Pay Date</Label>
                <Input
                  id="pay_date"
                  type="date"
                  value={formData.pay_date}
                  onChange={(e) => setFormData({ ...formData, pay_date: e.target.value })}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="starting_check_number">Starting Check Number (optional)</Label>
                <Input
                  id="starting_check_number"
                  inputMode="numeric"
                  value={formData.starting_check_number}
                  onChange={(e) => setFormData({ ...formData, starting_check_number: e.target.value })}
                  placeholder="Use current check settings"
                />
                <p className="text-xs text-gray-500">
                  {loadingCheckSettings
                    ? 'Checking current company check settings...'
                    : checkSettingsError
                      ? 'Could not load the current next check number. You can still enter an unused check number; the server will reject duplicates.'
                      : currentNextCheckNumber != null
                        ? `Current next check number is ${currentNextCheckNumber}. Leave blank to use that setting, or enter any unused check number if the physical stock is out of sequence.`
                        : 'Sets the company’s next payroll check number before checks are assigned. Leave blank to use the current check settings.'}
                </p>
                {checkSettingsError && !loadingCheckSettings && (
                  <div role="status" className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                    <div className="flex items-start gap-2">
                      <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
                      <div className="space-y-1">
                        <p>Current check-number settings did not load: {checkSettingsError}</p>
                        <button
                          type="button"
                          className="font-medium underline decoration-amber-400 underline-offset-2 hover:text-amber-900"
                          onClick={() => void loadCurrentNextCheckNumber()}
                        >
                          Try loading settings again
                        </button>
                      </div>
                    </div>
                  </div>
                )}
                {formData.starting_check_number.trim() &&
                  currentNextCheckNumber != null &&
                  /^\d+$/.test(formData.starting_check_number.trim()) &&
                  Number(formData.starting_check_number.trim()) < currentNextCheckNumber && (
                    <p className="text-xs font-medium text-amber-700">
                      This will move the sequence to a lower check number. That is allowed, but the number must not already be used.
                    </p>
                  )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="notes">Notes (optional)</Label>
                <Textarea
                  id="notes"
                  value={formData.notes}
                  onChange={(e) => setFormData({ ...formData, notes: e.target.value })}
                  placeholder="Any notes about this pay period..."
                />
              </div>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => handleCreateOpenChange(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? 'Creating...' : 'Create Pay Period'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Edit Pay Period Modal */}
      <Dialog open={isEditOpen} onOpenChange={handleEditOpenChange}>
        <DialogContent>
          <form onSubmit={handleEdit}>
            <DialogHeader>
              <DialogTitle>Edit Pay Period</DialogTitle>
              <DialogDescription>
                Update pay period dates and notes before commit.
              </DialogDescription>
            </DialogHeader>
            {editError && (
              <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                <div className="flex gap-2">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <p>{editError}</p>
                </div>
              </div>
            )}
            <div className="grid gap-4 py-4">
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="edit_start_date">Start Date</Label>
                  <Input
                    id="edit_start_date"
                    type="date"
                    value={editFormData.start_date}
                    onChange={(e) => setEditFormData({ ...editFormData, start_date: e.target.value })}
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="edit_end_date">End Date</Label>
                  <Input
                    id="edit_end_date"
                    type="date"
                    value={editFormData.end_date}
                    onChange={(e) => setEditFormData({ ...editFormData, end_date: e.target.value })}
                    required
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit_pay_date">Pay Date</Label>
                <Input
                  id="edit_pay_date"
                  type="date"
                  value={editFormData.pay_date}
                  onChange={(e) => setEditFormData({ ...editFormData, pay_date: e.target.value })}
                  required
                />
                {editingPayPeriod?.status !== 'draft' && (
                  editFormData.start_date !== editingPayPeriod?.start_date ||
                  editFormData.end_date !== editingPayPeriod?.end_date ||
                  editFormData.pay_date !== editingPayPeriod?.pay_date
                ) && (
                  <p className="text-xs text-amber-700">
                    Changing payroll dates will move this period back to draft so payroll can be recalculated with the new dates.
                  </p>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit_notes">Notes (optional)</Label>
                <Textarea
                  id="edit_notes"
                  value={editFormData.notes}
                  onChange={(e) => setEditFormData({ ...editFormData, notes: e.target.value })}
                  placeholder="Any notes about this pay period..."
                />
              </div>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => handleEditOpenChange(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={isEditSubmitting}>
                {isEditSubmitting ? 'Saving...' : 'Save Changes'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
