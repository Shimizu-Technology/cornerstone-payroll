import { useState, useEffect, useCallback } from 'react';
import { AlertCircle, ChevronDown, ChevronRight, CircleDollarSign, Link2, Plus, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Header } from '@/components/layout/Header';
import { employeeLoansApi, employeesApi } from '@/services/api';
import { formatCurrency, formatDate } from '@/lib/utils';
import type { EmployeeLoan, Employee, LoanSchedule, LoanTransaction } from '@/types';

const guamToday = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'Pacific/Guam' }).format(new Date());

const STATUS_COLORS: Record<string, string> = {
  active: 'bg-green-100 text-green-700',
  paid_off: 'bg-gray-100 text-gray-600',
  suspended: 'bg-yellow-100 text-yellow-700',
  stopped: 'bg-red-100 text-red-700',
};

export default function EmployeeLoans() {
  const [loans, setLoans] = useState<EmployeeLoan[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loanSchedules, setLoanSchedules] = useState<LoanSchedule[]>([]);
  const [setupGaps, setSetupGaps] = useState<LoanSchedule[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [expandedLoanId, setExpandedLoanId] = useState<number | null>(null);
  const [expandedLoan, setExpandedLoan] = useState<EmployeeLoan | null>(null);
  const [filterEmployee, setFilterEmployee] = useState<string>('');
  const [filterStatus, setFilterStatus] = useState<string>('active');
  const [formData, setFormData] = useState({
    tracking_mode: 'balance_tracked' as EmployeeLoan['tracking_mode'],
    balance_setup_mode: 'existing_balance' as 'new_loan' | 'existing_balance',
    employee_id: '',
    name: '',
    original_amount: '',
    opening_balance: '',
    payment_amount: '',
    start_date: '',
    first_deduction_date: '',
    balance_as_of: guamToday(),
    balance_source: 'quickbooks' as EmployeeLoan['balance_source'],
    principal_amount_known: false,
    schedule_key: 'new',
    notes: '',
  });
  const [formError, setFormError] = useState<string | null>(null);
  const [paymentAmount, setPaymentAmount] = useState('');
  const [additionAmount, setAdditionAmount] = useState('');
  const [additionNotes, setAdditionNotes] = useState('');
  const [creatingLoan, setCreatingLoan] = useState(false);
  const [recordingPayment, setRecordingPayment] = useState(false);
  const [recordingAddition, setRecordingAddition] = useState(false);
  const [expandingId, setExpandingId] = useState<number | null>(null);
  const [loanActionId, setLoanActionId] = useState<number | null>(null);
  const [loanActionError, setLoanActionError] = useState<string | null>(null);
  const [stopReason, setStopReason] = useState('');

  const loadLoans = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const params: Record<string, string | number> = {};
      if (filterEmployee) params.employee_id = parseInt(filterEmployee);
      if (filterStatus) params.status = filterStatus;
      const res = await employeeLoansApi.list(params);
      setLoans(res.loans);
      setLoanSchedules(res.loan_schedules || []);
      setSetupGaps(res.setup_gaps || []);
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : 'Could not load employee loans');
    } finally {
      setLoading(false);
    }
  }, [filterEmployee, filterStatus]);

  const loadEmployees = useCallback(async () => {
    try {
      const res = await employeesApi.list({ per_page: 250 });
      setEmployees(res.data);
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : 'Could not load employees');
    }
  }, []);

  useEffect(() => { loadLoans(); }, [loadLoans]);
  useEffect(() => { loadEmployees(); }, [loadEmployees]);

  const resetForm = () => setFormData({
    tracking_mode: 'balance_tracked',
    balance_setup_mode: 'existing_balance',
    employee_id: '',
    name: '',
    original_amount: '',
    opening_balance: '',
    payment_amount: '',
    start_date: '',
    first_deduction_date: '',
    balance_as_of: guamToday(),
    balance_source: 'quickbooks',
    principal_amount_known: false,
    schedule_key: 'new',
    notes: '',
  });

  const keepUpdatedLoanVisible = async (loan: EmployeeLoan) => {
    setExpandedLoan(loan);
    if (filterStatus && filterStatus !== loan.status) {
      setFilterStatus(loan.status);
      return;
    }
    await loadLoans();
  };

  const beginGapSetup = (gap: LoanSchedule) => {
    setFormData({
      tracking_mode: 'recurring_no_balance',
      balance_setup_mode: 'existing_balance',
      employee_id: String(gap.employee_id),
      name: gap.label,
      original_amount: '',
      opening_balance: '',
      payment_amount: gap.amount_type === 'fixed' && gap.amount ? String(gap.amount) : '',
      start_date: '',
    first_deduction_date: '',
      balance_as_of: guamToday(),
      balance_source: 'quickbooks',
      principal_amount_known: false,
      schedule_key: `${gap.kind}:${gap.id}`,
      notes: `Existing payroll deduction schedule: ${gap.label}.`,
    });
    setFormError(null);
    setShowForm(true);
    requestAnimationFrame(() => document.querySelector<HTMLElement>('[name="payment_amount"]')?.focus());
  };

  const handleExpandLoan = async (id: number) => {
    setLoanActionError(null);
    if (expandedLoanId === id) {
      setExpandedLoanId(null);
      setExpandedLoan(null);
      setStopReason('');
      return;
    }
    setExpandingId(id);
    setExpandedLoanId(id);
    setExpandedLoan(null);
    setStopReason('');
    try {
      const res = await employeeLoansApi.get(id);
      setExpandedLoan(res.loan);
    } catch (error) {
      setExpandedLoanId(null);
      setLoadError(error instanceof Error ? error.message : 'Could not load loan details');
    } finally {
      setExpandingId(null);
    }
  };

  const handleCreate = async () => {
    setFormError(null);
    const tracksBalance = formData.tracking_mode === 'balance_tracked';
    const isExistingBalance = formData.balance_setup_mode === 'existing_balance';
    if (!formData.employee_id || !formData.name.trim()) {
      setFormError('Choose an employee and enter a deduction name.');
      return;
    }
    if (tracksBalance && isExistingBalance && (!formData.opening_balance || !formData.balance_as_of)) {
      setFormError('Enter the confirmed balance and the date it was verified.');
      return;
    }
    if (tracksBalance && isExistingBalance && formData.principal_amount_known && !formData.original_amount) {
      setFormError('Enter the original principal, or mark it as unknown.');
      return;
    }
    if (tracksBalance && !isExistingBalance && !formData.original_amount) {
      setFormError('Enter the original amount for the new loan.');
      return;
    }
    if (!tracksBalance && !formData.schedule_key) {
      setFormError('Choose or create the payroll deduction schedule.');
      return;
    }
    if (formData.schedule_key && (!Number.isFinite(Number(formData.payment_amount)) || Number(formData.payment_amount) <= 0 || !formData.first_deduction_date)) {
      setFormError('Enter the payment per payday and first deduction payday.');
      return;
    }
    const [scheduleKind, scheduleId] = formData.schedule_key.split(':');
    setCreatingLoan(true);
    try {
      await employeeLoansApi.create({
        employee_id: parseInt(formData.employee_id),
        name: formData.name.trim(),
        tracking_mode: formData.tracking_mode,
        balance_setup_mode: formData.balance_setup_mode,
        original_amount: tracksBalance && formData.original_amount ? parseFloat(formData.original_amount) : undefined,
        opening_balance: tracksBalance && formData.opening_balance ? parseFloat(formData.opening_balance) : undefined,
        payment_amount: formData.payment_amount ? parseFloat(formData.payment_amount) : undefined,
        start_date: formData.start_date || undefined,
        first_deduction_date: formData.first_deduction_date || undefined,
        balance_as_of: tracksBalance && isExistingBalance ? formData.balance_as_of : undefined,
        balance_source: tracksBalance && isExistingBalance ? formData.balance_source || undefined : tracksBalance ? 'new_loan' : undefined,
        principal_amount_known: tracksBalance ? (isExistingBalance ? formData.principal_amount_known : true) : false,
        schedule_kind: scheduleKind ? scheduleKind as LoanSchedule['kind'] | 'new' : undefined,
        schedule_id: scheduleId ? parseInt(scheduleId, 10) : undefined,
        schedule_fingerprint: loanSchedules.find(schedule => schedule.employee_id === Number(formData.employee_id) && `${schedule.kind}:${schedule.id}` === formData.schedule_key)?.source_fingerprint,
        notes: formData.notes || undefined,
      });
      setShowForm(false);
      resetForm();
      await loadLoans();
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Failed to create the deduction');
    } finally {
      setCreatingLoan(false);
    }
  };

  const handleRecordPayment = async (loanId: number) => {
    if (!paymentAmount) return;
    setRecordingPayment(true);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.recordPayment(loanId, parseFloat(paymentAmount));
      await keepUpdatedLoanVisible(res.loan);
      setPaymentAmount('');
    } catch (error) {
      setLoanActionError(error instanceof Error ? error.message : 'Could not record the payment');
    } finally {
      setRecordingPayment(false);
    }
  };

  const handleRecordAddition = async (loanId: number) => {
    if (!additionAmount) return;
    setRecordingAddition(true);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.recordAddition(loanId, parseFloat(additionAmount), undefined, additionNotes || undefined);
      setExpandedLoan(res.loan);
      setAdditionAmount('');
      setAdditionNotes('');
      loadLoans();
    } catch (error) {
      setLoanActionError(error instanceof Error ? error.message : 'Could not add to the loan balance');
    } finally {
      setRecordingAddition(false);
    }
  };

  const refreshExpandedLoan = async (loanId: number) => {
    const res = await employeeLoansApi.get(loanId);
    setExpandedLoan(res.loan);
  };

  const handleMarkPaidOff = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Mark ${loan.employee_name}'s ${loan.name} as paid off? This will set the balance to $0 and keep the loan history for audit.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.markPaidOff(loan.id, undefined, 'Marked paid off from Employee Loans page');
      await keepUpdatedLoanVisible(res.loan);
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to mark loan paid off');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleSuspend = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Pause ${loan.employee_name}'s ${loan.name}? It will not be deducted until it is resumed.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.suspend(loan.id, 'Paused from Employee Loans page');
      await keepUpdatedLoanVisible(res.loan);
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to pause deduction');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleReactivate = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Resume ${loan.employee_name}'s ${loan.name}? It may be deducted from future paychecks after recalculation.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.reactivate(loan.id, 'Resumed from Employee Loans page');
      await keepUpdatedLoanVisible(res.loan);
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to resume deduction');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleStop = async (loan: EmployeeLoan) => {
    if (!stopReason.trim()) return;
    const confirmed = window.confirm(
      `Stop ${loan.employee_name}'s ${loan.name} permanently? This keeps the full deduction history and cannot be resumed.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.stop(loan.id, stopReason.trim());
      await keepUpdatedLoanVisible(res.loan);
      setStopReason('');
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to stop deduction');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleDeleteLoan = async (loan: EmployeeLoan) => {
    const recordLabel = loan.tracking_mode === 'recurring_no_balance' ? 'deduction' : 'loan';
    const confirmed = window.confirm(
      `Delete ${loan.employee_name}'s ${loan.name}? Only accidental ${recordLabel}s without payment history can be deleted.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      await employeeLoansApi.delete(loan.id);
      setExpandedLoanId(null);
      setExpandedLoan(null);
      await loadLoans();
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : `Failed to delete ${recordLabel}`);
      await refreshExpandedLoan(loan.id).catch(() => undefined);
    } finally {
      setLoanActionId(null);
    }
  };

  const fmt = (v: number) => formatCurrency(v);
  const selectedEmployeeSchedules = loanSchedules.filter((schedule) => String(schedule.employee_id) === formData.employee_id && !schedule.tracked);
  const visibleSetupGaps = setupGaps.filter((gap) => !filterEmployee || String(gap.employee_id) === filterEmployee);

  return (
    <>
      <Header
        title="Loans & Recurring Deductions"
        description="Track installment balances and open-ended payroll deductions"
        actions={
          <Button onClick={() => {
            if (showForm) resetForm();
            setShowForm(!showForm);
          }}>
            {showForm ? 'Cancel' : <><Plus className="mr-2 h-4 w-4" />Set up deduction</>}
          </Button>
        }
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {loadError && (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800" role="alert">
            <span className="flex items-center gap-2"><AlertCircle className="h-4 w-4" />{loadError}</span>
            <Button size="sm" variant="outline" onClick={() => { void loadLoans(); void loadEmployees(); }}>Try again</Button>
          </div>
        )}

        {/* Filters */}
        <div className="grid grid-cols-1 gap-3 sm:flex sm:gap-4 [&>select]:w-full sm:[&>select]:w-auto">
          <select className="border rounded px-3 py-2 text-sm" value={filterEmployee} onChange={e => setFilterEmployee(e.target.value)}>
            <option value="">All Employees</option>
            {employees.map(emp => (
              <option key={emp.id} value={emp.id}>{emp.last_name}, {emp.first_name}</option>
            ))}
          </select>
          <select className="border rounded px-3 py-2 text-sm" value={filterStatus} onChange={e => setFilterStatus(e.target.value)}>
            <option value="active">Active</option>
            <option value="">All Statuses</option>
            <option value="paid_off">Paid Off</option>
            <option value="suspended">Suspended</option>
            <option value="stopped">Stopped</option>
          </select>
        </div>

        {!loading && visibleSetupGaps.length > 0 && (
          <Card className="border-amber-200 bg-amber-50/70 p-5">
            <div className="flex items-start gap-3">
              <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-white text-amber-700 shadow-sm"><Link2 className="h-5 w-5" /></span>
              <div className="min-w-0 flex-1">
                <h2 className="font-display text-lg font-extrabold tracking-tight text-amber-950">Loan deductions needing a tracking choice</h2>
                <p className="mt-1 max-w-3xl text-sm leading-6 text-amber-800">Choose whether each existing deduction has a known balance or simply continues until the client tells Cornerstone to stop. Payroll cannot safely guess.</p>
                <div className="mt-4 grid gap-3 lg:grid-cols-2">
                  {visibleSetupGaps.map((gap) => (
                    <div key={`${gap.kind}:${gap.id}`} className="flex flex-col gap-3 rounded-2xl border border-amber-200 bg-white p-4 sm:flex-row sm:items-center">
                      <div className="min-w-0 flex-1">
                        <p className="font-semibold text-neutral-950">{gap.employee_name}</p>
                        <p className="mt-1 text-sm text-neutral-600">{gap.label} · {gap.amount_type === 'percentage' ? `${gap.percentage}% per payroll` : gap.amount ? `${fmt(gap.amount)} per payroll` : 'manual amount'}</p>
                      </div>
                      <Button size="sm" onClick={() => beginGapSetup(gap)}>Choose tracking</Button>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </Card>
        )}

        {/* Create Form */}
        {showForm && (
          <Card className="border-primary-100 p-5">
            <h3 className="font-display text-xl font-extrabold tracking-tight text-neutral-950">Set up a payroll deduction</h3>
            <p className="mt-1 text-sm text-neutral-600">Start with the one fact that controls the workflow: does Cornerstone know the remaining balance?</p>
            <div className="my-4 grid gap-2 rounded-2xl bg-neutral-100 p-1 sm:grid-cols-2">
              <button type="button" className={`min-h-16 rounded-xl px-4 py-3 text-left text-sm ${formData.tracking_mode === 'recurring_no_balance' ? 'bg-white text-primary-800 shadow-sm' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, tracking_mode: 'recurring_no_balance', balance_setup_mode: 'existing_balance', original_amount: '', opening_balance: '', balance_as_of: guamToday(), balance_source: 'quickbooks', principal_amount_known: false, schedule_key: previous.schedule_key || 'new' }))}><span className="block font-semibold">Recurring deduction — no balance</span><span className="mt-1 block text-xs font-normal leading-5">Deduct the set amount until an authorized person pauses or stops it.</span></button>
              <button type="button" className={`min-h-16 rounded-xl px-4 py-3 text-left text-sm ${formData.tracking_mode === 'balance_tracked' ? 'bg-white text-primary-800 shadow-sm' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, tracking_mode: 'balance_tracked' }))}><span className="block font-semibold">Installment loan — track balance</span><span className="mt-1 block text-xs font-normal leading-5">Cap the final payment at the remaining balance, then mark it paid off.</span></button>
            </div>
            {formData.tracking_mode === 'balance_tracked' && (
              <div className="mb-4 grid gap-2 rounded-2xl border border-neutral-200 p-1 sm:grid-cols-2">
                <button type="button" className={`min-h-11 rounded-xl px-4 text-sm font-semibold ${formData.balance_setup_mode === 'existing_balance' ? 'bg-neutral-100 text-primary-800' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, balance_setup_mode: 'existing_balance' }))}>Bring in an existing balance</button>
                <button type="button" className={`min-h-11 rounded-xl px-4 text-sm font-semibold ${formData.balance_setup_mode === 'new_loan' ? 'bg-neutral-100 text-primary-800' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, balance_setup_mode: 'new_loan' }))}>Start a new loan</button>
              </div>
            )}
            {formError && <p className="mb-4 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700" role="alert">{formError}</p>}
            <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Employee <span className="text-danger-600">*</span>
                <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.employee_id} onChange={e => setFormData(p => ({ ...p, employee_id: e.target.value, schedule_key: 'new' }))}>
                  <option value="">Select an employee</option>
                  {employees.filter(e => e.status === 'active').map(emp => (
                    <option key={emp.id} value={emp.id}>{emp.last_name}, {emp.first_name}</option>
                  ))}
                </select>
              </label>
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Deduction name <span className="text-danger-600">*</span>
                <Input placeholder="Example: Employee loan" value={formData.name} onChange={e => setFormData(p => ({ ...p, name: e.target.value }))} />
              </label>
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Payroll deduction schedule
                <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.schedule_key} onChange={e => setFormData(p => ({ ...p, schedule_key: e.target.value }))} disabled={!formData.employee_id}>
                  <option value="new">Create a payroll repayment schedule</option>
                  {formData.tracking_mode === 'balance_tracked' && <option value="">Track balance only — no payroll deductions</option>}
                  {selectedEmployeeSchedules.map((schedule) => (
                    <option key={`${schedule.kind}:${schedule.id}`} value={`${schedule.kind}:${schedule.id}`}>{schedule.label}</option>
                  ))}
                </select>
              </label>
              {formData.schedule_key.startsWith('recurring_adjustment:') && <p className="text-sm text-neutral-600 md:col-span-2">This replaces the old free-text deduction with a named ledger schedule, so it is not deducted twice.</p>}
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Payment per payroll
                <Input name="payment_amount" placeholder="$0.00" type="text" inputMode="decimal" value={formData.payment_amount} onChange={e => setFormData(p => ({ ...p, payment_amount: e.target.value }))} />
              </label>
              {formData.tracking_mode === 'balance_tracked' && (formData.balance_setup_mode === 'existing_balance' ? (
                <>
                  <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                    Confirmed opening balance <span className="text-danger-600">*</span>
                    <Input name="opening_balance" placeholder="$0.00" type="text" inputMode="decimal" value={formData.opening_balance} onChange={e => setFormData(p => ({ ...p, opening_balance: e.target.value }))} />
                  </label>
                  <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                    Balance verified as of <span className="text-danger-600">*</span>
                    <Input type="date" value={formData.balance_as_of} onChange={e => setFormData(p => ({ ...p, balance_as_of: e.target.value }))} />
                  </label>
                  <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                    Verification source
                    <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.balance_source || ''} onChange={e => setFormData(p => ({ ...p, balance_source: e.target.value as EmployeeLoan['balance_source'] }))}>
                      <option value="quickbooks">Verified in QuickBooks</option>
                      <option value="statement">Verified from a loan statement</option>
                      <option value="employee_confirmation">Confirmed by the employee</option>
                      <option value="other_verified">Other verified source</option>
                    </select>
                  </label>
                  <label className="flex items-start gap-3 rounded-xl border border-neutral-200 p-3 text-sm text-neutral-700">
                    <input type="checkbox" className="mt-1 h-4 w-4 rounded border-neutral-300 text-primary-700" checked={formData.principal_amount_known} onChange={e => setFormData(p => ({ ...p, principal_amount_known: e.target.checked }))} />
                    <span><span className="font-semibold text-neutral-900">Original principal is known</span><span className="mt-1 block text-xs leading-5 text-neutral-500">Leave off when only the current balance is known.</span></span>
                  </label>
                  {formData.principal_amount_known && <label className="space-y-1.5 text-sm font-semibold text-neutral-800">Original principal <span className="text-danger-600">*</span><Input placeholder="$0.00" type="text" inputMode="decimal" value={formData.original_amount} onChange={e => setFormData(p => ({ ...p, original_amount: e.target.value }))} /></label>}
                </>
              ) : (
                <>
                  <label className="space-y-1.5 text-sm font-semibold text-neutral-800">Original loan amount <span className="text-danger-600">*</span><Input placeholder="$0.00" type="text" inputMode="decimal" value={formData.original_amount} onChange={e => setFormData(p => ({ ...p, original_amount: e.target.value }))} /></label>
                  <label className="space-y-1.5 text-sm font-semibold text-neutral-800">Loan start date<Input type="date" value={formData.start_date} onChange={e => setFormData(p => ({ ...p, start_date: e.target.value }))} /></label>
                </>
              ))}
              {formData.schedule_key && <label className="space-y-1.5 text-sm font-semibold text-neutral-800">First deduction payday<Input type="date" value={formData.first_deduction_date} onChange={e => setFormData(p => ({ ...p, first_deduction_date: e.target.value }))} /><span className="block text-xs font-normal text-neutral-600">{formData.tracking_mode === 'balance_tracked' ? 'Deduct each payday, cap the final payment at the remaining balance, then stop automatically.' : 'Deduct each payday until an authorized person pauses or stops it.'}</span></label>}
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800 md:col-span-2">Notes or verification reference (does not change deductions)<Input placeholder="Optional source detail" value={formData.notes} onChange={e => setFormData(p => ({ ...p, notes: e.target.value }))} /></label>
            </div>
            <p className="mt-3 text-xs leading-5 text-neutral-500">Every linked deduction is recorded only when payroll is committed. Recalculating never changes a balance or creates payment history.</p>
            <div className="mt-3 grid grid-cols-1 gap-2 sm:flex">
              <Button onClick={handleCreate} disabled={creatingLoan}>
                {creatingLoan ? 'Creating...' : formData.tracking_mode === 'recurring_no_balance' ? 'Create Deduction' : 'Create Loan'}
              </Button>
              <Button variant="outline" onClick={() => { resetForm(); setShowForm(false); }} disabled={creatingLoan}>Cancel</Button>
            </div>
          </Card>
        )}

        {/* Summary */}
        <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
          <Card className="p-4">
            <p className="text-sm text-gray-500">Active Deductions</p>
            <p className="text-2xl font-bold">{loans.filter(l => l.status === 'active').length}</p>
          </Card>
          <Card className="p-4">
            <p className="text-sm text-gray-500">Tracked Balance Outstanding</p>
            <p className="text-2xl font-bold">{fmt(loans.filter(l => l.status === 'active' && l.tracking_mode === 'balance_tracked').reduce((sum, loan) => sum + Number(loan.current_balance || 0), 0))}</p>
          </Card>
          <Card className="p-4">
            <p className="text-sm text-gray-500">No-Balance Deductions</p>
            <p className="text-2xl font-bold">{loans.filter(l => l.status === 'active' && l.tracking_mode === 'recurring_no_balance').length}</p>
          </Card>
        </div>

        {/* Loans List */}
        {loading ? (
          <p className="text-gray-500">Loading loans...</p>
        ) : loans.length === 0 ? (
          <Card className="p-8 text-center text-gray-500"><CircleDollarSign className="mx-auto mb-3 h-8 w-8 text-neutral-400" />No loans or recurring deductions match these filters.</Card>
        ) : (
          <div className="space-y-3">
            {loans.map(loan => (
              <Card key={loan.id} className="overflow-hidden">
                <button
                  type="button"
                  className="flex w-full flex-col gap-3 p-4 text-left hover:bg-gray-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-600 sm:flex-row sm:items-center sm:justify-between"
                  onClick={() => handleExpandLoan(loan.id)}
                  aria-expanded={expandedLoanId === loan.id}
                >
                  <div className="flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-semibold">{loan.employee_name}</span>
                      <span className="text-gray-400">—</span>
                      <span className="text-gray-700">{loan.name}</span>
                      <Badge variant="outline">{loan.tracking_mode === 'balance_tracked' ? 'Balance tracked' : 'No balance'}</Badge>
                      <Badge className={STATUS_COLORS[loan.status]}>{loan.status === 'paid_off' ? 'Paid off' : `${loan.status.charAt(0).toUpperCase()}${loan.status.slice(1)}`}</Badge>
                    </div>
                    <div className="mt-2 grid grid-cols-1 gap-1 text-sm text-gray-500 sm:flex sm:flex-wrap sm:gap-x-6 sm:gap-y-1">
                      {loan.tracking_mode === 'balance_tracked' ? (
                        <>
                          <span>{loan.principal_amount_known ? `Original: ${fmt(Number(loan.original_amount || 0))}` : `Opening balance: ${fmt(Number(loan.opening_balance || 0))}`}</span>
                          <span className="font-semibold text-gray-900">Balance: {fmt(Number(loan.current_balance || 0))}</span>
                          <span>Verified as of: {loan.balance_as_of ? formatDate(loan.balance_as_of) : '—'}</span>
                        </>
                      ) : <span className="font-semibold text-gray-900">No balance tracked — continues until stopped</span>}
                      {loan.scheduled ? <span>{loan.schedule_active ? `${fmt(loan.payment_amount || 0)} each payday${loan.effective_first_deduction_date ? ` from ${formatDate(loan.effective_first_deduction_date)}` : ''}${loan.last_deduction_date ? ` through ${formatDate(loan.last_deduction_date)}${loan.tracking_mode === 'balance_tracked' ? ', or until paid' : ''}` : loan.tracking_mode === 'balance_tracked' ? ', until paid' : ', until stopped'}` : 'Payroll deductions stopped'}</span> : <span>Balance tracking only</span>}
                    </div>
                  </div>
                  <span className="text-gray-400">{expandedLoanId === loan.id ? <ChevronDown className="h-5 w-5" /> : <ChevronRight className="h-5 w-5" />}</span>
                </button>

                {expandedLoanId === loan.id && (
                  <div className="border-t p-4 bg-gray-50">
                    {expandingId === loan.id ? (
                      <div className="flex items-center gap-2 py-4 text-sm text-gray-500">
                        <div className="w-4 h-4 animate-spin rounded-full border-2 border-gray-300 border-t-indigo-600" />
                        Loading loan details...
                      </div>
                    ) : !expandedLoan ? (
                      <p className="text-sm text-gray-400">Failed to load details</p>
                    ) : (
                    <>
                    {loanActionError && (
                      <div className="mb-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                        {loanActionError}
                      </div>
                    )}

                    <div className={`mb-4 flex items-start gap-3 rounded-2xl border px-4 py-3 text-sm ${expandedLoan.tracking_mode === 'balance_tracked' ? 'border-emerald-200 bg-emerald-50 text-emerald-900' : 'border-blue-200 bg-blue-50 text-blue-950'}`}>
                      <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" />
                      <div>
                        {expandedLoan.tracking_mode === 'balance_tracked' ? (
                          <>
                            <p className="font-semibold">Verified balance source: {(expandedLoan.balance_source || 'not recorded').replace('_', ' ')}</p>
                            <p className="mt-1 text-xs leading-5">Opening balance {fmt(Number(expandedLoan.opening_balance || 0))} as of {expandedLoan.balance_as_of ? formatDate(expandedLoan.balance_as_of) : '—'}{expandedLoan.created_by_name ? ` · Recorded by ${expandedLoan.created_by_name}` : ''}.</p>
                          </>
                        ) : (
                          <>
                            <p className="font-semibold">Recurring deduction without a known balance</p>
                            <p className="mt-1 text-xs leading-5">Cornerstone records every committed deduction but does not guess a payoff balance. It continues until paused or permanently stopped.</p>
                          </>
                        )}
                      </div>
                    </div>

                    {expandedLoan.scheduled && !['paid_off', 'stopped'].includes(expandedLoan.status) && (
                      <form className="mb-4 flex flex-wrap items-end gap-3" onSubmit={async (event) => {
                        event.preventDefault();
                        const values = new FormData(event.currentTarget);
                        setLoanActionId(loan.id);
                        setLoanActionError(null);
                        try {
                          const result = await employeeLoansApi.update(loan.id, { payment_amount: Number(values.get('scheduled_payment')), first_deduction_date: String(values.get('first_payday')) });
                          setExpandedLoan(result.loan);
                          await loadLoans();
                        } catch (error) {
                          setLoanActionError(error instanceof Error ? error.message : 'Could not update repayment schedule');
                        } finally { setLoanActionId(null); }
                      }}>
                        <label className="text-sm font-medium">Payment each payday<Input name="scheduled_payment" type="number" min="0.01" step="0.01" required defaultValue={expandedLoan.payment_amount} /></label>
                        <label className="text-sm font-medium">First deduction payday<Input name="first_payday" type="date" required defaultValue={expandedLoan.first_deduction_date || ''} /></label>
                        <Button type="submit" disabled={loanActionId === loan.id}>Save repayment schedule</Button>
                        <p className="w-full text-xs text-neutral-600">Changes apply when editable payroll is recalculated. {expandedLoan.tracking_mode === 'balance_tracked' ? 'The final deduction is capped at the balance.' : 'This continues until it is paused or permanently stopped.'}</p>
                      </form>
                    )}
                    {/* Lifecycle Actions */}
                    <div className="mb-4 grid grid-cols-1 gap-2 rounded-2xl border border-gray-200 bg-white p-3 sm:flex sm:flex-wrap sm:items-center [&>button]:w-full sm:[&>button]:w-auto">
                      <div className="sm:mr-auto">
                        <p className="text-sm font-semibold text-gray-900">Deduction status controls</p>
                        <p className="text-xs text-gray-500">Pause temporarily, close permanently, or remove an accidental record without rewriting history.</p>
                      </div>
                      {loan.tracking_mode === 'balance_tracked' && loan.status !== 'paid_off' && (
                        <Button size="sm" variant="outline" onClick={() => handleMarkPaidOff(expandedLoan)} disabled={loanActionId === loan.id}>
                          Mark Paid Off
                        </Button>
                      )}
                      {loan.status === 'active' && (
                        <Button size="sm" variant="outline" onClick={() => handleSuspend(expandedLoan)} disabled={loanActionId === loan.id}>
                          Pause
                        </Button>
                      )}
                      {loan.status === 'suspended' && (
                        <Button size="sm" variant="outline" onClick={() => handleReactivate(expandedLoan)} disabled={loanActionId === loan.id}>
                          Resume
                        </Button>
                      )}
                      <Button size="sm" variant="danger" onClick={() => handleDeleteLoan(expandedLoan)} disabled={loanActionId === loan.id}>
                        Delete Accidental {loan.tracking_mode === 'recurring_no_balance' ? 'Deduction' : 'Loan'}
                      </Button>
                    </div>

                    {loan.tracking_mode === 'recurring_no_balance' && !['paid_off', 'stopped'].includes(loan.status) && (
                      <div className="mb-4 grid gap-2 rounded-2xl border border-red-200 bg-red-50 p-3 sm:grid-cols-[1fr_auto] sm:items-end">
                        <label className="space-y-1.5 text-sm font-medium text-red-950">Reason to stop permanently<Input value={stopReason} onChange={(event) => setStopReason(event.target.value)} placeholder="Example: Client confirmed final deduction" /></label>
                        <Button variant="danger" onClick={() => void handleStop(expandedLoan)} disabled={!stopReason.trim() || loanActionId === loan.id}>Stop Permanently</Button>
                        <p className="text-xs leading-5 text-red-800 sm:col-span-2">Use Pause for a temporary hold. Stop Permanently closes this schedule and requires a new authorized setup to resume later.</p>
                      </div>
                    )}

                    {/* Quick Actions */}
                    {loan.status === 'active' && (
                      <div className="mb-4 grid grid-cols-1 gap-3 lg:flex lg:flex-wrap lg:gap-4">
                        <div className="grid grid-cols-1 gap-2 sm:flex sm:items-center">
                          <Input className="w-full px-2 py-1 text-sm sm:w-28" type="text" inputMode="decimal" placeholder="Payment $" value={paymentAmount} onChange={e => setPaymentAmount(e.target.value)} />
                          <Button size="sm" onClick={() => handleRecordPayment(loan.id)} disabled={!paymentAmount || recordingPayment}>
                            {recordingPayment ? 'Recording...' : expandedLoan.tracking_mode === 'balance_tracked' ? 'Record Payment' : 'Record Manual Deduction'}
                          </Button>
                        </div>
                        {expandedLoan.tracking_mode === 'balance_tracked' && <div className="grid grid-cols-1 gap-2 sm:flex sm:items-center">
                          <Input className="w-full px-2 py-1 text-sm sm:w-28" type="text" inputMode="decimal" placeholder="Addition $" value={additionAmount} onChange={e => setAdditionAmount(e.target.value)} />
                          <Input className="w-full px-2 py-1 text-sm sm:w-32" placeholder="Notes" value={additionNotes} onChange={e => setAdditionNotes(e.target.value)} />
                          <Button size="sm" variant="outline" onClick={() => handleRecordAddition(loan.id)} disabled={!additionAmount || recordingAddition}>
                            {recordingAddition ? 'Adding...' : 'Add to Loan'}
                          </Button>
                        </div>}
                      </div>
                    )}

                    {/* Transaction History */}
                    <h4 className="font-semibold text-sm mb-2">Transaction History</h4>
                    {expandedLoan.transactions && expandedLoan.transactions.length > 0 ? (
                      <div className="overflow-x-auto">
                        <table className={`${expandedLoan.tracking_mode === 'balance_tracked' ? 'min-w-[42rem]' : 'min-w-[30rem]'} w-full text-sm`}>
                        <thead>
                          <tr className="border-b text-left text-gray-500">
                            <th className="py-1 pr-4">Date</th>
                            <th className="py-1 pr-4">Type</th>
                            {expandedLoan.tracking_mode === 'balance_tracked' && <th className="py-1 pr-4 text-right">Before</th>}
                            <th className="py-1 pr-4 text-right">Amount</th>
                            {expandedLoan.tracking_mode === 'balance_tracked' && <th className="py-1 pr-4 text-right">After</th>}
                            <th className="py-1">Notes</th>
                          </tr>
                        </thead>
                        <tbody>
                          {(expandedLoan.transactions as LoanTransaction[]).map(txn => (
                            <tr key={txn.id} className="border-b last:border-0">
                              <td className="py-1 pr-4">{txn.transaction_date}</td>
                              <td className="py-1 pr-4">
                                <Badge variant="outline" className={txn.transaction_type === 'payment' ? 'text-green-700' : 'text-blue-700'}>
                                  {txn.transaction_type}
                                </Badge>
                              </td>
                              {expandedLoan.tracking_mode === 'balance_tracked' && <td className="py-1 pr-4 text-right">{fmt(Number(txn.balance_before || 0))}</td>}
                              <td className="py-1 pr-4 text-right font-medium">
                                {txn.transaction_type === 'payment' ? `-${fmt(txn.amount)}` : `+${fmt(txn.amount)}`}
                              </td>
                              {expandedLoan.tracking_mode === 'balance_tracked' && <td className="py-1 pr-4 text-right">{fmt(Number(txn.balance_after || 0))}</td>}
                              <td className="py-1 text-gray-500">
                                <span>{txn.notes || '—'}</span>
                                <span className="block text-xs text-neutral-400">{txn.source.replace('_', ' ')}{txn.recorded_by_name ? ` · ${txn.recorded_by_name}` : ''}</span>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                        </table>
                      </div>
                    ) : (
                      <p className="text-gray-500 text-sm italic">No transactions recorded</p>
                    )}
                    </>
                    )}
                  </div>
                )}
              </Card>
            ))}
          </div>
        )}
      </div>
    </>
  );
}
