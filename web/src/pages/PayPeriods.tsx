import { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
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
import { Textarea } from '@/components/ui/textarea';
import { formatCurrency, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { PayPeriod } from '@/types';

export function PayPeriods() {
  const navigate = useNavigate();
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<string | undefined>();
  const [statusCounts, setStatusCounts] = useState<Record<string, number>>({});
  
  // Modal state
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [actionInFlight, setActionInFlight] = useState<string | null>(null);
  const [formData, setFormData] = useState({
    start_date: '',
    end_date: '',
    pay_date: '',
    notes: '',
  });

  // Load pay periods
  const loadPayPeriods = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await payPeriodsApi.list({ status: statusFilter });
      setPayPeriods(response.pay_periods);
      setStatusCounts(response.meta.statuses);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay periods');
    } finally {
      setLoading(false);
    }
  }, [statusFilter]);

  useEffect(() => {
    loadPayPeriods();
  }, [loadPayPeriods]);

  const handleCreate = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (formData.end_date <= formData.start_date) {
      setError('End date must be after start date');
      return;
    }
    if (formData.pay_date < formData.end_date) {
      setError('Pay date must be on or after end date');
      return;
    }

    try {
      setIsSubmitting(true);
      setError(null);
      await payPeriodsApi.create(formData);
      setIsCreateOpen(false);
      setFormData({ start_date: '', end_date: '', pay_date: '', notes: '' });
      loadPayPeriods();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create pay period');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleRunPayroll = async (id: number) => {
    try {
      setActionInFlight(`run-${id}`);
      setError(null);
      await payPeriodsApi.runPayroll(id);
      loadPayPeriods();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      setActionInFlight(null);
    }
  };

  const handleApprove = async (id: number) => {
    try {
      setActionInFlight(`approve-${id}`);
      setError(null);
      await payPeriodsApi.approve(id);
      loadPayPeriods();
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
      loadPayPeriods();
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
      loadPayPeriods();
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
      notes: '',
    });
  };

  return (
    <div>
      <Header
        title="Pay Periods"
        description="Manage payroll periods and processing"
        actions={
          <Button onClick={() => { setDefaultDates(); setIsCreateOpen(true); }}>
            New Pay Period
          </Button>
        }
      />

      <div className="p-8">
        {/* Error display */}
        {error && (
          <div className="mb-4 p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Status filter tabs */}
        <div className="mb-4 flex gap-2">
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

        {/* Pay Period Table */}
        <Card>
          {loading ? (
            <div className="p-8 text-center text-gray-500">Loading...</div>
          ) : payPeriods.length === 0 ? (
            <div className="p-8 text-center text-gray-500">
              No pay periods found. Create your first pay period to get started.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Pay Period</TableHead>
                  <TableHead>Pay Date</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Gross Pay</TableHead>
                  <TableHead>Net Pay</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {payPeriods.map((period) => {
                  const statusConfig = payPeriodStatusConfig[period.status];
                  return (
                    <TableRow key={period.id}>
                      <TableCell>
                        <span className="font-medium text-gray-900">
                          {formatDateRange(period.start_date, period.end_date)}
                        </span>
                      </TableCell>
                      <TableCell>
                        <span className="text-sm text-gray-700">
                          {new Date(period.pay_date).toLocaleDateString('en-US', {
                            weekday: 'short',
                            month: 'short',
                            day: 'numeric',
                          })}
                        </span>
                      </TableCell>
                      <TableCell>
                        <span className="text-sm text-gray-700">
                          {period.employee_count || 0}
                        </span>
                      </TableCell>
                      <TableCell>
                        <span className="font-medium text-gray-900">
                          {period.total_gross ? formatCurrency(period.total_gross) : '—'}
                        </span>
                      </TableCell>
                      <TableCell>
                        <span className="font-medium text-gray-900">
                          {period.total_net ? formatCurrency(period.total_net) : '—'}
                        </span>
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={
                            period.status === 'committed' ? 'success' :
                            period.status === 'approved' ? 'info' :
                            period.status === 'calculated' ? 'warning' :
                            'default'
                          }
                        >
                          {statusConfig?.label || period.status}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex items-center justify-end gap-2">
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => navigate(`/pay-periods/${period.id}`)}
                          >
                            View
                          </Button>
                          {period.status === 'draft' && (
                            <>
                              <Button
                                size="sm"
                                onClick={() => handleRunPayroll(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Calculate
                              </Button>
                              <Button
                                variant="ghost"
                                size="sm"
                                className="text-red-600 hover:text-red-700"
                                onClick={() => handleDelete(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Delete
                              </Button>
                            </>
                          )}
                          {period.status === 'calculated' && (
                            <>
                              <Button
                                size="sm"
                                onClick={() => handleApprove(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Approve
                              </Button>
                              <Button
                                variant="outline"
                                size="sm"
                                onClick={() => handleRunPayroll(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Recalculate
                              </Button>
                            </>
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
          )}
        </Card>

        {/* Workflow explanation */}
        <Card className="mt-8">
          <div className="p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Payroll Workflow</h3>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-gray-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-gray-600">1</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Draft</p>
                  <p className="text-sm text-gray-500">Create pay period</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-yellow-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-yellow-600">2</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Calculated</p>
                  <p className="text-sm text-gray-500">Review totals</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-blue-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-blue-600">3</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Approved</p>
                  <p className="text-sm text-gray-500">Ready to commit</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
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
      <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
        <DialogContent>
          <form onSubmit={handleCreate}>
            <DialogHeader>
              <DialogTitle>New Pay Period</DialogTitle>
              <DialogDescription>
                Create a new pay period. Default dates are set for a biweekly schedule.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              <div className="grid grid-cols-2 gap-4">
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
              <Button type="button" variant="outline" onClick={() => setIsCreateOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? 'Creating...' : 'Create Pay Period'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
