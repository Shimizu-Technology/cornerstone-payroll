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
    balance_setup_mode: 'existing_balance' as 'new_loan' | 'existing_balance',
    employee_id: '',
    name: '',
    original_amount: '',
    opening_balance: '',
    payment_amount: '',
    start_date: '',
    balance_as_of: guamToday(),
    balance_source: 'quickbooks' as EmployeeLoan['balance_source'],
    principal_amount_known: false,
    schedule_key: '',
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
    balance_setup_mode: 'existing_balance',
    employee_id: '',
    name: '',
    original_amount: '',
    opening_balance: '',
    payment_amount: '',
    start_date: '',
    balance_as_of: guamToday(),
    balance_source: 'quickbooks',
    principal_amount_known: false,
    schedule_key: '',
    notes: '',
  });

  const beginGapSetup = (gap: LoanSchedule) => {
    setFormData({
      balance_setup_mode: 'existing_balance',
      employee_id: String(gap.employee_id),
      name: gap.label,
      original_amount: '',
      opening_balance: '',
      payment_amount: gap.amount_type === 'fixed' && gap.amount ? String(gap.amount) : '',
      start_date: '',
      balance_as_of: guamToday(),
      balance_source: 'quickbooks',
      principal_amount_known: false,
      schedule_key: `${gap.kind}:${gap.id}`,
      notes: `Opening balance to be confirmed for ${gap.label}.`,
    });
    setFormError(null);
    setShowForm(true);
    requestAnimationFrame(() => document.querySelector<HTMLElement>('[name="opening_balance"]')?.focus());
  };

  const handleExpandLoan = async (id: number) => {
    setLoanActionError(null);
    if (expandedLoanId === id) {
      setExpandedLoanId(null);
      setExpandedLoan(null);
      return;
    }
    setExpandingId(id);
    setExpandedLoanId(id);
    setExpandedLoan(null);
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
    const isExistingBalance = formData.balance_setup_mode === 'existing_balance';
    if (!formData.employee_id || !formData.name.trim()) {
      setFormError('Choose an employee and enter a loan name.');
      return;
    }
    if (isExistingBalance && (!formData.opening_balance || !formData.balance_as_of)) {
      setFormError('Enter the confirmed balance and the date it was verified.');
      return;
    }
    if (isExistingBalance && formData.principal_amount_known && !formData.original_amount) {
      setFormError('Enter the original principal, or mark it as unknown.');
      return;
    }
    if (!isExistingBalance && !formData.original_amount) {
      setFormError('Enter the original amount for the new loan.');
      return;
    }
    const [scheduleKind, scheduleId] = formData.schedule_key.split(':');
    setCreatingLoan(true);
    try {
      await employeeLoansApi.create({
        employee_id: parseInt(formData.employee_id),
        name: formData.name.trim(),
        balance_setup_mode: formData.balance_setup_mode,
        original_amount: formData.original_amount ? parseFloat(formData.original_amount) : undefined,
        opening_balance: formData.opening_balance ? parseFloat(formData.opening_balance) : undefined,
        payment_amount: formData.payment_amount ? parseFloat(formData.payment_amount) : undefined,
        start_date: formData.start_date || undefined,
        balance_as_of: isExistingBalance ? formData.balance_as_of : undefined,
        balance_source: isExistingBalance ? formData.balance_source : 'new_loan',
        principal_amount_known: isExistingBalance ? formData.principal_amount_known : true,
        schedule_kind: scheduleKind ? scheduleKind as LoanSchedule['kind'] : undefined,
        schedule_id: scheduleId ? parseInt(scheduleId, 10) : undefined,
        notes: formData.notes || undefined,
      });
      setShowForm(false);
      resetForm();
      await loadLoans();
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Failed to create loan');
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
      setExpandedLoan(res.loan);
      setPaymentAmount('');
      loadLoans();
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
      setExpandedLoan(res.loan);
      await loadLoans();
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to mark loan paid off');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleSuspend = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Suspend ${loan.employee_name}'s ${loan.name}? The balance will stay unchanged, but the loan will no longer count as active.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.suspend(loan.id, 'Suspended from Employee Loans page');
      setExpandedLoan(res.loan);
      await loadLoans();
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to suspend loan');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleReactivate = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Reactivate ${loan.employee_name}'s ${loan.name}? This loan will count as active again and may be deducted from future paychecks.`
    );
    if (!confirmed) return;

    setLoanActionId(loan.id);
    setLoanActionError(null);
    try {
      const res = await employeeLoansApi.reactivate(loan.id, 'Reactivated from Employee Loans page');
      setExpandedLoan(res.loan);
      await loadLoans();
    } catch (err) {
      setLoanActionError(err instanceof Error ? err.message : 'Failed to reactivate loan');
    } finally {
      setLoanActionId(null);
    }
  };

  const handleDeleteLoan = async (loan: EmployeeLoan) => {
    const confirmed = window.confirm(
      `Delete ${loan.employee_name}'s ${loan.name}? Only accidental loans without payment history can be deleted.`
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
      setLoanActionError(err instanceof Error ? err.message : 'Failed to delete loan');
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
        title="Employee Loans"
        description="Track installment loans, advances, and payment history"
        actions={
          <Button onClick={() => {
            if (showForm) resetForm();
            setShowForm(!showForm);
          }}>
            {showForm ? 'Cancel' : <><Plus className="mr-2 h-4 w-4" />Set up loan</>}
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
          </select>
        </div>

        {!loading && visibleSetupGaps.length > 0 && (
          <Card className="border-amber-200 bg-amber-50/70 p-5">
            <div className="flex items-start gap-3">
              <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-white text-amber-700 shadow-sm"><Link2 className="h-5 w-5" /></span>
              <div className="min-w-0 flex-1">
                <h2 className="font-display text-lg font-extrabold tracking-tight text-amber-950">Loan deductions needing a confirmed balance</h2>
                <p className="mt-1 max-w-3xl text-sm leading-6 text-amber-800">These deductions are already scheduled on employee profiles, but no active balance ledger is linked. Confirm the outstanding balance before the next live payroll.</p>
                <div className="mt-4 grid gap-3 lg:grid-cols-2">
                  {visibleSetupGaps.map((gap) => (
                    <div key={`${gap.kind}:${gap.id}`} className="flex flex-col gap-3 rounded-2xl border border-amber-200 bg-white p-4 sm:flex-row sm:items-center">
                      <div className="min-w-0 flex-1">
                        <p className="font-semibold text-neutral-950">{gap.employee_name}</p>
                        <p className="mt-1 text-sm text-neutral-600">{gap.label} · {gap.amount_type === 'percentage' ? `${gap.percentage}% per payroll` : gap.amount ? `${fmt(gap.amount)} per payroll` : 'manual amount'}</p>
                      </div>
                      <Button size="sm" onClick={() => beginGapSetup(gap)}>Confirm balance</Button>
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
            <h3 className="font-display text-xl font-extrabold tracking-tight text-neutral-950">Set up an employee loan</h3>
            <p className="mt-1 text-sm text-neutral-600">Choose whether this is a new loan or an existing balance being brought into Cornerstone.</p>
            <div className="my-4 grid gap-2 rounded-2xl bg-neutral-100 p-1 sm:grid-cols-2">
              <button type="button" className={`min-h-11 rounded-xl px-4 text-sm font-semibold ${formData.balance_setup_mode === 'existing_balance' ? 'bg-white text-primary-800 shadow-sm' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, balance_setup_mode: 'existing_balance' }))}>Bring in an existing balance</button>
              <button type="button" className={`min-h-11 rounded-xl px-4 text-sm font-semibold ${formData.balance_setup_mode === 'new_loan' ? 'bg-white text-primary-800 shadow-sm' : 'text-neutral-600'}`} onClick={() => setFormData((previous) => ({ ...previous, balance_setup_mode: 'new_loan' }))}>Start a new loan</button>
            </div>
            {formError && <p className="mb-4 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700" role="alert">{formError}</p>}
            <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Employee <span className="text-danger-600">*</span>
                <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.employee_id} onChange={e => setFormData(p => ({ ...p, employee_id: e.target.value, schedule_key: '' }))}>
                  <option value="">Select an employee</option>
                  {employees.filter(e => e.status === 'active').map(emp => (
                    <option key={emp.id} value={emp.id}>{emp.last_name}, {emp.first_name}</option>
                  ))}
                </select>
              </label>
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Loan name <span className="text-danger-600">*</span>
                <Input placeholder="Example: Employee loan" value={formData.name} onChange={e => setFormData(p => ({ ...p, name: e.target.value }))} />
              </label>
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Payroll deduction schedule
                <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.schedule_key} onChange={e => setFormData(p => ({ ...p, schedule_key: e.target.value }))} disabled={!formData.employee_id}>
                  <option value="">No automatic deduction schedule</option>
                  {selectedEmployeeSchedules.map((schedule) => (
                    <option key={`${schedule.kind}:${schedule.id}`} value={`${schedule.kind}:${schedule.id}`}>{schedule.label}</option>
                  ))}
                </select>
              </label>
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800">
                Payment per payroll
                <Input placeholder="$0.00" type="text" inputMode="decimal" value={formData.payment_amount} onChange={e => setFormData(p => ({ ...p, payment_amount: e.target.value }))} />
              </label>
              {formData.balance_setup_mode === 'existing_balance' ? (
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
                    <select className="min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3 text-sm font-normal" value={formData.balance_source} onChange={e => setFormData(p => ({ ...p, balance_source: e.target.value as EmployeeLoan['balance_source'] }))}>
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
              )}
              <label className="space-y-1.5 text-sm font-semibold text-neutral-800 md:col-span-2">Notes or verification reference<Input placeholder="Optional source detail" value={formData.notes} onChange={e => setFormData(p => ({ ...p, notes: e.target.value }))} /></label>
            </div>
            <p className="mt-3 text-xs leading-5 text-neutral-500">A linked payroll deduction reduces this ledger only when payroll is committed. Imported paid checks stay unchanged.</p>
            <div className="mt-3 grid grid-cols-1 gap-2 sm:flex">
              <Button onClick={handleCreate} disabled={creatingLoan}>
                {creatingLoan ? 'Creating...' : 'Create Loan'}
              </Button>
              <Button variant="outline" onClick={() => { resetForm(); setShowForm(false); }} disabled={creatingLoan}>Cancel</Button>
            </div>
          </Card>
        )}

        {/* Summary */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <Card className="p-4">
            <p className="text-sm text-gray-500">Active Loans</p>
            <p className="text-2xl font-bold">{loans.filter(l => l.status === 'active').length}</p>
          </Card>
          <Card className="p-4">
            <p className="text-sm text-gray-500">Total Outstanding</p>
            <p className="text-2xl font-bold">{fmt(loans.filter(l => l.status === 'active').reduce((sum, loan) => sum + Number(loan.current_balance), 0))}</p>
          </Card>
          <Card className="p-4">
            <p className="text-sm text-gray-500">Opening Balances</p>
            <p className="text-2xl font-bold">{fmt(loans.reduce((sum, loan) => sum + Number(loan.opening_balance), 0))}</p>
          </Card>
        </div>

        {/* Loans List */}
        {loading ? (
          <p className="text-gray-500">Loading loans...</p>
        ) : loans.length === 0 ? (
          <Card className="p-8 text-center text-gray-500"><CircleDollarSign className="mx-auto mb-3 h-8 w-8 text-neutral-400" />No loans match these filters.</Card>
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
                      <Badge className={STATUS_COLORS[loan.status]}>{loan.status.replace('_', ' ')}</Badge>
                    </div>
                    <div className="mt-2 grid grid-cols-1 gap-1 text-sm text-gray-500 sm:flex sm:flex-wrap sm:gap-x-6 sm:gap-y-1">
                      <span>{loan.principal_amount_known ? `Original: ${fmt(loan.original_amount)}` : `Opening balance: ${fmt(loan.opening_balance)}`}</span>
                      <span className="font-semibold text-gray-900">Balance: {fmt(loan.current_balance)}</span>
                      {loan.payment_amount && <span>Per Period: {fmt(loan.payment_amount)}</span>}
                      <span>Verified as of: {formatDate(loan.balance_as_of)}</span>
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

                    <div className="mb-4 flex items-start gap-3 rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900">
                      <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0" />
                      <div>
                        <p className="font-semibold">Balance source: {expandedLoan.balance_source.replace('_', ' ')}</p>
                        <p className="mt-1 text-xs leading-5 text-emerald-800">Opening balance {fmt(expandedLoan.opening_balance)} as of {formatDate(expandedLoan.balance_as_of)}{expandedLoan.created_by_name ? ` · Recorded by ${expandedLoan.created_by_name}` : ''}.</p>
                      </div>
                    </div>

                    {/* Lifecycle Actions */}
                    <div className="mb-4 grid grid-cols-1 gap-2 rounded-2xl border border-gray-200 bg-white p-3 sm:flex sm:flex-wrap sm:items-center [&>button]:w-full sm:[&>button]:w-auto">
                      <div className="sm:mr-auto">
                        <p className="text-sm font-semibold text-gray-900">Loan status controls</p>
                        <p className="text-xs text-gray-500">Close, pause, or remove accidental loan records without changing payroll history.</p>
                      </div>
                      {loan.status !== 'paid_off' && (
                        <Button size="sm" variant="outline" onClick={() => handleMarkPaidOff(expandedLoan)} disabled={loanActionId === loan.id}>
                          Mark Paid Off
                        </Button>
                      )}
                      {loan.status === 'active' && (
                        <Button size="sm" variant="outline" onClick={() => handleSuspend(expandedLoan)} disabled={loanActionId === loan.id}>
                          Suspend
                        </Button>
                      )}
                      {loan.status === 'suspended' && (
                        <Button size="sm" variant="outline" onClick={() => handleReactivate(expandedLoan)} disabled={loanActionId === loan.id}>
                          Reactivate
                        </Button>
                      )}
                      <Button size="sm" variant="danger" onClick={() => handleDeleteLoan(expandedLoan)} disabled={loanActionId === loan.id}>
                        Delete Accidental Loan
                      </Button>
                    </div>

                    {/* Quick Actions */}
                    {loan.status === 'active' && (
                      <div className="mb-4 grid grid-cols-1 gap-3 lg:flex lg:flex-wrap lg:gap-4">
                        <div className="grid grid-cols-1 gap-2 sm:flex sm:items-center">
                          <Input className="w-full px-2 py-1 text-sm sm:w-28" type="text" inputMode="decimal" placeholder="Payment $" value={paymentAmount} onChange={e => setPaymentAmount(e.target.value)} />
                          <Button size="sm" onClick={() => handleRecordPayment(loan.id)} disabled={!paymentAmount || recordingPayment}>
                            {recordingPayment ? 'Recording...' : 'Record Payment'}
                          </Button>
                        </div>
                        <div className="grid grid-cols-1 gap-2 sm:flex sm:items-center">
                          <Input className="w-full px-2 py-1 text-sm sm:w-28" type="text" inputMode="decimal" placeholder="Addition $" value={additionAmount} onChange={e => setAdditionAmount(e.target.value)} />
                          <Input className="w-full px-2 py-1 text-sm sm:w-32" placeholder="Notes" value={additionNotes} onChange={e => setAdditionNotes(e.target.value)} />
                          <Button size="sm" variant="outline" onClick={() => handleRecordAddition(loan.id)} disabled={!additionAmount || recordingAddition}>
                            {recordingAddition ? 'Adding...' : 'Add to Loan'}
                          </Button>
                        </div>
                      </div>
                    )}

                    {/* Transaction History */}
                    <h4 className="font-semibold text-sm mb-2">Transaction History</h4>
                    {expandedLoan.transactions && expandedLoan.transactions.length > 0 ? (
                      <div className="overflow-x-auto">
                        <table className="min-w-[42rem] w-full text-sm">
                        <thead>
                          <tr className="border-b text-left text-gray-500">
                            <th className="py-1 pr-4">Date</th>
                            <th className="py-1 pr-4">Type</th>
                            <th className="py-1 pr-4 text-right">Before</th>
                            <th className="py-1 pr-4 text-right">Amount</th>
                            <th className="py-1 pr-4 text-right">After</th>
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
                              <td className="py-1 pr-4 text-right">{fmt(txn.balance_before)}</td>
                              <td className="py-1 pr-4 text-right font-medium">
                                {txn.transaction_type === 'payment' ? `-${fmt(txn.amount)}` : `+${fmt(txn.amount)}`}
                              </td>
                              <td className="py-1 pr-4 text-right">{fmt(txn.balance_after)}</td>
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
