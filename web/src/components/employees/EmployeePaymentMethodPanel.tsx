import { useEffect, useRef, useState, type ReactElement } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { employeesApi } from '@/services/api';
import { employeePaymentDelivery } from '@/lib/employee-payment-delivery';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { ActionFeedback, useFeedback, useFeedbackState } from '@/components/ui/action-feedback';
import type { Employee, PaymentDeliveryMethod } from '@/types';

export function EmployeePaymentMethodPanel({ employee, onEmployeeReload }: { employee: Employee; onEmployeeReload: () => Promise<void> }): ReactElement {
  const { hasCapability } = useAuth();
  const { notify } = useFeedback();
  const [editing, setEditing] = useState(false);
  const [method, setMethod] = useState<PaymentDeliveryMethod>(employee.payment_delivery_method || 'paper_check');
  const [saving, setSaving] = useState(false);
  const [error, setError, errorAttempt] = useFeedbackState<string | null>(null);
  const scope = `${employee.company_id}:${employee.id}`;
  const activeRef = useRef(false);
  useEffect(() => { activeRef.current = true; return () => { activeRef.current = false; }; }, []);
  const scopeRef = useRef(scope);
  scopeRef.current = scope;
  const canChange = hasCapability('payroll_operations');

  const save = async (): Promise<void> => {
    const savingScope = scope;
    setSaving(true);
    setError(null);
    let saved: Awaited<ReturnType<typeof employeesApi.update>>;
    try { saved = await employeesApi.update(employee.id, { payment_delivery_method: method }, employee.company_id); }
    catch (caught) {
      if (activeRef.current && scopeRef.current === savingScope) { setError(caught instanceof Error ? caught.message : 'Could not save the future payment method.'); setSaving(false); }
      return;
    }
    if (!activeRef.current || scopeRef.current !== savingScope) return;
    notify({ tone: 'success', message: `${[employee.first_name, employee.middle_name, employee.last_name].filter(Boolean).join(' ')}: future payroll default saved as ${method === 'direct_deposit' ? 'Direct deposit' : 'Paper check'}. Existing payroll delivery choices were preserved. No bank transfer was sent.` });
    const reapprovals = saved.payment_method_review?.reapproval_pay_period_ids || [];
    if (reapprovals.length) notify({ tone: 'warning', message: `The delivery choices were preserved. Review and approve pay runs ${reapprovals.map(id => `#${id}`).join(', ')} again before processing; their older payment-method snapshots were updated.` });
    setSaving(false);
    setEditing(false);
    try { await onEmployeeReload(); }
    catch { notify({ tone: 'warning', message: 'The future payment method was saved, but the employee screen could not refresh. Reload to see the saved setting.' }); }
  };

  return <Card>
    <CardHeader><CardTitle>Payment method</CardTitle><p className="mt-2 text-sm leading-6 text-neutral-600">Choose how future payrolls should be paid. To change a current payroll, use Change payment method in that pay run.</p></CardHeader>
    <CardContent className="space-y-4">
      <p className="font-semibold text-neutral-950">Future default: {employeePaymentDelivery(employee).label}</p>
      <p className="text-sm leading-6 text-neutral-600">{employeePaymentDelivery(employee).detail}</p>
      {error && <ActionFeedback tone="error" message={error} retryKey={errorAttempt} />}
      {editing ? <fieldset disabled={saving} className="space-y-4">
        <Select label="Future payroll payment method" value={method} onChange={event => setMethod(event.target.value as PaymentDeliveryMethod)}><option value="paper_check">Paper check</option><option value="direct_deposit">Direct deposit</option></Select>
        <p className="text-xs leading-5 text-neutral-600">Existing pay runs retain their delivery choice. Confirm direct-deposit enrollment with the employer or bank; this setting does not send a transfer.</p>
        <div className="flex flex-wrap justify-end gap-2"><Button variant="outline" onClick={() => { setEditing(false); setError(null); }}>Cancel</Button><Button onClick={() => void save()}>{saving ? 'Saving…' : 'Save future default'}</Button></div>
      </fieldset> : canChange ? <Button variant="outline" onClick={() => { setMethod(employee.payment_delivery_method || 'paper_check'); setError(null); setEditing(true); }}>Change future payment method</Button> : <p className="text-sm text-neutral-600">Ask the payroll team to change this employee’s future payment method.</p>}
    </CardContent>
  </Card>;
}
