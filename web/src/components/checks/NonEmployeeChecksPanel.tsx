import { useState, useEffect, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { nonEmployeeChecksApi } from '@/services/api';
import type { NonEmployeeCheck, NonEmployeeCheckType } from '@/types';

interface NonEmployeeChecksPanelProps {
  payPeriodId: number;
  companyId: number;
}

const CHECK_TYPE_LABELS: Record<NonEmployeeCheckType, string> = {
  contractor: 'Contractor',
  tax_deposit: 'Tax Deposit',
  child_support: 'Child Support',
  garnishment: 'Garnishment',
  vendor: 'Vendor',
  reimbursement: 'Reimbursement',
  other: 'Other',
};

const STATUS_COLORS: Record<string, string> = {
  pending: 'bg-gray-100 text-gray-700',
  unprinted: 'bg-yellow-100 text-yellow-700',
  printed: 'bg-green-100 text-green-700',
  voided: 'bg-red-100 text-red-700',
};

export function NonEmployeeChecksPanel({ payPeriodId }: NonEmployeeChecksPanelProps) {
  const [checks, setChecks] = useState<NonEmployeeCheck[]>([]);
  const [loading, setLoading] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({
    payable_to: '',
    amount: '',
    check_type: 'other' as NonEmployeeCheckType,
    memo: '',
    description: '',
    reference_number: '',
    check_number: '',
  });
  const [formError, setFormError] = useState<string | null>(null);
  const [voidingId, setVoidingId] = useState<number | null>(null);
  const [voidReason, setVoidReason] = useState('');

  const loadChecks = useCallback(async () => {
    setLoading(true);
    try {
      const res = await nonEmployeeChecksApi.list({ pay_period_id: payPeriodId });
      setChecks(res.non_employee_checks);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => { loadChecks(); }, [loadChecks]);

  const handleCreate = async () => {
    setFormError(null);
    if (!formData.payable_to || !formData.amount) {
      setFormError('Payable To and Amount are required');
      return;
    }
    try {
      await nonEmployeeChecksApi.create({
        pay_period_id: payPeriodId,
        payable_to: formData.payable_to,
        amount: parseFloat(formData.amount),
        check_type: formData.check_type,
        memo: formData.memo || undefined,
        description: formData.description || undefined,
        reference_number: formData.reference_number || undefined,
        check_number: formData.check_number || undefined,
      });
      setShowForm(false);
      setFormData({ payable_to: '', amount: '', check_type: 'other', memo: '', description: '', reference_number: '', check_number: '' });
      loadChecks();
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Failed to create check');
    }
  };

  const handleVoid = async (id: number) => {
    if (!voidReason) return;
    try {
      await nonEmployeeChecksApi.voidCheck(id, voidReason);
      setVoidingId(null);
      setVoidReason('');
      loadChecks();
    } catch {
      // ignore
    }
  };

  const handleMarkPrinted = async (id: number) => {
    try {
      await nonEmployeeChecksApi.markPrinted(id);
      loadChecks();
    } catch {
      // ignore
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Delete this non-employee check?')) return;
    try {
      await nonEmployeeChecksApi.delete(id);
      loadChecks();
    } catch {
      // ignore
    }
  };

  const fmt = (v: number | string) => `$${Number(v).toFixed(2)}`;

  return (
    <Card>
      <div className="p-4 border-b bg-blue-50">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="font-semibold text-blue-900">Non-Employee Checks</h3>
            <p className="text-sm text-blue-700 mt-1">
              Tax deposits, garnishments, vendor payments, etc.
            </p>
          </div>
          <Button size="sm" onClick={() => setShowForm(!showForm)}>
            {showForm ? 'Cancel' : '+ Add Check'}
          </Button>
        </div>
      </div>

      {showForm && (
        <div className="p-4 border-b bg-blue-50/30">
          {formError && <p className="text-sm text-red-600 mb-2">{formError}</p>}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <input className="border rounded px-3 py-2 text-sm" placeholder="Payable To *" value={formData.payable_to} onChange={e => setFormData(p => ({ ...p, payable_to: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Amount *" type="number" step="0.01" value={formData.amount} onChange={e => setFormData(p => ({ ...p, amount: e.target.value }))} />
            <select className="border rounded px-3 py-2 text-sm" value={formData.check_type} onChange={e => setFormData(p => ({ ...p, check_type: e.target.value as NonEmployeeCheckType }))}>
              {Object.entries(CHECK_TYPE_LABELS).map(([val, label]) => (
                <option key={val} value={val}>{label}</option>
              ))}
            </select>
            <input className="border rounded px-3 py-2 text-sm" placeholder="Check #" value={formData.check_number} onChange={e => setFormData(p => ({ ...p, check_number: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Memo" value={formData.memo} onChange={e => setFormData(p => ({ ...p, memo: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Reference #" value={formData.reference_number} onChange={e => setFormData(p => ({ ...p, reference_number: e.target.value }))} />
          </div>
          <textarea className="mt-2 w-full border rounded px-3 py-2 text-sm" placeholder="Description" rows={2} value={formData.description} onChange={e => setFormData(p => ({ ...p, description: e.target.value }))} />
          <div className="mt-3 flex gap-2">
            <Button size="sm" onClick={handleCreate}>Create Check</Button>
            <Button size="sm" variant="outline" onClick={() => setShowForm(false)}>Cancel</Button>
          </div>
        </div>
      )}

      <div className="p-4">
        {loading ? (
          <p className="text-sm text-gray-500">Loading...</p>
        ) : checks.length === 0 ? (
          <p className="text-sm text-gray-500 italic">No non-employee checks for this pay period.</p>
        ) : (
          <div className="space-y-3">
            {checks.map(check => (
              <div key={check.id} className={`flex items-center justify-between p-3 border rounded-lg ${check.voided ? 'bg-red-50 border-red-200' : 'hover:bg-gray-50'}`}>
                <div className="flex-1">
                  <div className="flex items-center gap-2">
                    <span className="font-medium text-sm">{check.payable_to}</span>
                    <Badge className={STATUS_COLORS[check.check_status] || 'bg-gray-100 text-gray-700'}>
                      {check.check_status}
                    </Badge>
                    <Badge variant="outline">{CHECK_TYPE_LABELS[check.check_type as NonEmployeeCheckType] || check.check_type}</Badge>
                  </div>
                  <div className="flex items-center gap-4 text-xs text-gray-500 mt-1">
                    <span className="font-semibold text-gray-900">{fmt(check.amount)}</span>
                    {check.check_number && <span>Check #{check.check_number}</span>}
                    {check.memo && <span>{check.memo}</span>}
                    {check.reference_number && <span>Ref: {check.reference_number}</span>}
                  </div>
                </div>
                <div className="flex gap-1 shrink-0">
                  {!check.voided && !check.printed_at && (
                    <Button size="sm" variant="outline" onClick={() => handleMarkPrinted(check.id)}>
                      Mark Printed
                    </Button>
                  )}
                  {!check.voided && voidingId !== check.id && (
                    <Button size="sm" variant="outline" className="text-red-600 border-red-300" onClick={() => setVoidingId(check.id)}>
                      Void
                    </Button>
                  )}
                  {voidingId === check.id && (
                    <div className="flex gap-1">
                      <input className="border rounded px-2 py-1 text-xs w-32" placeholder="Reason..." value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                      <Button size="sm" variant="destructive" onClick={() => handleVoid(check.id)}>Confirm</Button>
                      <Button size="sm" variant="outline" onClick={() => { setVoidingId(null); setVoidReason(''); }}>Cancel</Button>
                    </div>
                  )}
                  {!check.printed_at && !check.voided && (
                    <Button size="sm" variant="ghost" className="text-red-400" onClick={() => handleDelete(check.id)}>
                      Delete
                    </Button>
                  )}
                </div>
              </div>
            ))}

            <div className="pt-2 border-t flex justify-between text-sm font-semibold">
              <span>Total ({checks.filter(c => !c.voided).length} checks)</span>
              <span>{fmt(checks.filter(c => !c.voided).reduce((sum, c) => sum + c.amount, 0))}</span>
            </div>
          </div>
        )}
      </div>
    </Card>
  );
}
