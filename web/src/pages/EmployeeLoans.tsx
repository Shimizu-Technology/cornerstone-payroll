import { useState, useEffect, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Header } from '@/components/layout/Header';
import { employeeLoansApi, employeesApi } from '@/services/api';
import type { EmployeeLoan, Employee, LoanTransaction } from '@/types';

const STATUS_COLORS: Record<string, string> = {
  active: 'bg-green-100 text-green-700',
  paid_off: 'bg-gray-100 text-gray-600',
  suspended: 'bg-yellow-100 text-yellow-700',
};

export default function EmployeeLoans() {
  const [loans, setLoans] = useState<EmployeeLoan[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [expandedLoanId, setExpandedLoanId] = useState<number | null>(null);
  const [expandedLoan, setExpandedLoan] = useState<EmployeeLoan | null>(null);
  const [filterEmployee, setFilterEmployee] = useState<string>('');
  const [filterStatus, setFilterStatus] = useState<string>('');
  const [formData, setFormData] = useState({
    employee_id: '',
    name: '',
    original_amount: '',
    payment_amount: '',
    start_date: '',
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

  const loadLoans = useCallback(async () => {
    setLoading(true);
    try {
      const params: Record<string, string | number> = {};
      if (filterEmployee) params.employee_id = parseInt(filterEmployee);
      if (filterStatus) params.status = filterStatus;
      const res = await employeeLoansApi.list(params);
      setLoans(res.loans);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }, [filterEmployee, filterStatus]);

  const loadEmployees = useCallback(async () => {
    try {
      const res = await employeesApi.list();
      setEmployees(res.data);
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => { loadLoans(); }, [loadLoans]);
  useEffect(() => { loadEmployees(); }, [loadEmployees]);

  const handleExpandLoan = async (id: number) => {
    if (expandedLoanId === id) {
      setExpandedLoanId(null);
      setExpandedLoan(null);
      return;
    }
    setExpandingId(id);
    setExpandedLoanId(id);
    try {
      const res = await employeeLoansApi.get(id);
      setExpandedLoan(res.loan);
    } catch {
      setExpandedLoanId(null);
    } finally {
      setExpandingId(null);
    }
  };

  const handleCreate = async () => {
    setFormError(null);
    if (!formData.employee_id || !formData.name || !formData.original_amount) {
      setFormError('Employee, Name, and Amount are required');
      return;
    }
    setCreatingLoan(true);
    try {
      await employeeLoansApi.create({
        employee_id: parseInt(formData.employee_id),
        name: formData.name,
        original_amount: parseFloat(formData.original_amount),
        payment_amount: formData.payment_amount ? parseFloat(formData.payment_amount) : undefined,
        start_date: formData.start_date || undefined,
        notes: formData.notes || undefined,
      });
      setShowForm(false);
      setFormData({ employee_id: '', name: '', original_amount: '', payment_amount: '', start_date: '', notes: '' });
      loadLoans();
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Failed to create loan');
    } finally {
      setCreatingLoan(false);
    }
  };

  const handleRecordPayment = async (loanId: number) => {
    if (!paymentAmount) return;
    setRecordingPayment(true);
    try {
      const res = await employeeLoansApi.recordPayment(loanId, parseFloat(paymentAmount));
      setExpandedLoan(res.loan);
      setPaymentAmount('');
      loadLoans();
    } catch {
      // ignore
    } finally {
      setRecordingPayment(false);
    }
  };

  const handleRecordAddition = async (loanId: number) => {
    if (!additionAmount) return;
    setRecordingAddition(true);
    try {
      const res = await employeeLoansApi.recordAddition(loanId, parseFloat(additionAmount), undefined, additionNotes || undefined);
      setExpandedLoan(res.loan);
      setAdditionAmount('');
      setAdditionNotes('');
      loadLoans();
    } catch {
      // ignore
    } finally {
      setRecordingAddition(false);
    }
  };

  const fmt = (v: number) => `$${v.toFixed(2)}`;

  return (
    <>
      <Header
        title="Employee Loans"
        description="Track installment loans, advances, and payment history"
        actions={
          <Button onClick={() => setShowForm(!showForm)}>
            {showForm ? 'Cancel' : '+ New Loan'}
          </Button>
        }
      />

      <div className="p-6 space-y-6">
        {/* Filters */}
        <div className="flex gap-4">
          <select className="border rounded px-3 py-2 text-sm" value={filterEmployee} onChange={e => setFilterEmployee(e.target.value)}>
            <option value="">All Employees</option>
            {employees.map(emp => (
              <option key={emp.id} value={emp.id}>{emp.last_name}, {emp.first_name}</option>
            ))}
          </select>
          <select className="border rounded px-3 py-2 text-sm" value={filterStatus} onChange={e => setFilterStatus(e.target.value)}>
            <option value="">All Statuses</option>
            <option value="active">Active</option>
            <option value="paid_off">Paid Off</option>
            <option value="suspended">Suspended</option>
          </select>
        </div>

        {/* Create Form */}
        {showForm && (
          <Card className="p-4">
            <h3 className="font-semibold mb-3">Create New Loan</h3>
            {formError && <p className="text-sm text-red-600 mb-2">{formError}</p>}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
              <select className="border rounded px-3 py-2 text-sm" value={formData.employee_id} onChange={e => setFormData(p => ({ ...p, employee_id: e.target.value }))}>
                <option value="">Select Employee *</option>
                {employees.filter(e => e.status === 'active').map(emp => (
                  <option key={emp.id} value={emp.id}>{emp.last_name}, {emp.first_name}</option>
                ))}
              </select>
              <input className="border rounded px-3 py-2 text-sm" placeholder="Loan Name *" value={formData.name} onChange={e => setFormData(p => ({ ...p, name: e.target.value }))} />
              <input className="border rounded px-3 py-2 text-sm" placeholder="Original Amount *" type="number" step="0.01" value={formData.original_amount} onChange={e => setFormData(p => ({ ...p, original_amount: e.target.value }))} />
              <input className="border rounded px-3 py-2 text-sm" placeholder="Payment per Period" type="number" step="0.01" value={formData.payment_amount} onChange={e => setFormData(p => ({ ...p, payment_amount: e.target.value }))} />
              <input className="border rounded px-3 py-2 text-sm" type="date" value={formData.start_date} onChange={e => setFormData(p => ({ ...p, start_date: e.target.value }))} />
              <input className="border rounded px-3 py-2 text-sm" placeholder="Notes" value={formData.notes} onChange={e => setFormData(p => ({ ...p, notes: e.target.value }))} />
            </div>
            <div className="mt-3 flex gap-2">
              <Button onClick={handleCreate} disabled={creatingLoan}>
                {creatingLoan ? 'Creating...' : 'Create Loan'}
              </Button>
              <Button variant="outline" onClick={() => setShowForm(false)} disabled={creatingLoan}>Cancel</Button>
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
            <p className="text-2xl font-bold">{fmt(loans.filter(l => l.status === 'active').reduce((s, l) => s + l.current_balance, 0))}</p>
          </Card>
          <Card className="p-4">
            <p className="text-sm text-gray-500">Total Original</p>
            <p className="text-2xl font-bold">{fmt(loans.reduce((s, l) => s + l.original_amount, 0))}</p>
          </Card>
        </div>

        {/* Loans List */}
        {loading ? (
          <p className="text-gray-500">Loading loans...</p>
        ) : loans.length === 0 ? (
          <Card className="p-8 text-center text-gray-500">No loans found</Card>
        ) : (
          <div className="space-y-3">
            {loans.map(loan => (
              <Card key={loan.id} className="overflow-hidden">
                <div
                  className="p-4 flex items-center justify-between cursor-pointer hover:bg-gray-50"
                  onClick={() => handleExpandLoan(loan.id)}
                >
                  <div className="flex-1">
                    <div className="flex items-center gap-2">
                      <span className="font-semibold">{loan.employee_name}</span>
                      <span className="text-gray-400">—</span>
                      <span className="text-gray-700">{loan.name}</span>
                      <Badge className={STATUS_COLORS[loan.status]}>{loan.status.replace('_', ' ')}</Badge>
                    </div>
                    <div className="flex gap-6 text-sm text-gray-500 mt-1">
                      <span>Original: {fmt(loan.original_amount)}</span>
                      <span className="font-semibold text-gray-900">Balance: {fmt(loan.current_balance)}</span>
                      {loan.payment_amount && <span>Per Period: {fmt(loan.payment_amount)}</span>}
                      {loan.start_date && <span>Started: {loan.start_date}</span>}
                    </div>
                  </div>
                  <span className="text-gray-400">{expandedLoanId === loan.id ? '▼' : '▶'}</span>
                </div>

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
                    {/* Quick Actions */}
                    {loan.status === 'active' && (
                      <div className="flex flex-wrap gap-4 mb-4">
                        <div className="flex items-center gap-2">
                          <input className="border rounded px-2 py-1 text-sm w-28" type="number" step="0.01" placeholder="Payment $" value={paymentAmount} onChange={e => setPaymentAmount(e.target.value)} />
                          <Button size="sm" onClick={() => handleRecordPayment(loan.id)} disabled={!paymentAmount || recordingPayment}>
                            {recordingPayment ? 'Recording...' : 'Record Payment'}
                          </Button>
                        </div>
                        <div className="flex items-center gap-2">
                          <input className="border rounded px-2 py-1 text-sm w-28" type="number" step="0.01" placeholder="Addition $" value={additionAmount} onChange={e => setAdditionAmount(e.target.value)} />
                          <input className="border rounded px-2 py-1 text-sm w-32" placeholder="Notes" value={additionNotes} onChange={e => setAdditionNotes(e.target.value)} />
                          <Button size="sm" variant="outline" onClick={() => handleRecordAddition(loan.id)} disabled={!additionAmount || recordingAddition}>
                            {recordingAddition ? 'Adding...' : 'Add to Loan'}
                          </Button>
                        </div>
                      </div>
                    )}

                    {/* Transaction History */}
                    <h4 className="font-semibold text-sm mb-2">Transaction History</h4>
                    {expandedLoan.transactions && expandedLoan.transactions.length > 0 ? (
                      <table className="w-full text-sm">
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
                              <td className="py-1 text-gray-500">{txn.notes || '—'}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
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
