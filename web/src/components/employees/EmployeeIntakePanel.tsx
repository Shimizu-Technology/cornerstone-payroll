import { useLayoutEffect, useRef, useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { employeeIntakeApi } from '@/services/employee-intake-api';
import { intakeFieldLabels } from '@/lib/employee-intake';
import { formatDate, formatGuamDateTime } from '@/lib/utils';
import type { Employee } from '@/types';

export function EmployeeIntakePanel({ companyId, employee, onUpdated }: { companyId: number; employee: Employee; onUpdated: (employee: Employee) => void }) {
  const { hasCapability } = useAuth();
  const canReview = hasCapability?.('manage_client_configuration') ?? false;
  const [dueOn, setDueOn] = useState(employee.intake_readiness?.exception?.follow_up_due_on || '');
  const [eligibleFrom, setEligibleFrom] = useState(employee.intake_readiness?.exception?.payroll_eligible_from || employee.hire_date || '');
  const [reason, setReason] = useState('');
  const [acknowledged, setAcknowledged] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const scopeRef = useRef(`${companyId}:${employee.id}`);
  useLayoutEffect(() => {
    scopeRef.current = `${companyId}:${employee.id}`;
    return () => { scopeRef.current = ''; };
  }, [companyId, employee.id]);
  const readiness = employee.intake_readiness;
  const exception = readiness?.exception;
  if (!readiness || !exception) return null;
  const missingWithholding = readiness.missing_fields.includes('withholding_election');

  const save = async (confirm: boolean) => {
    const scope = `${companyId}:${employee.id}`;
    setSaving(true);
    setError(null);
    try {
      const response = await employeeIntakeApi.updateException(companyId, employee.id, {
        follow_up_due_on: dueOn,
        ...(confirm ? { confirm_payroll_setup: true, payroll_eligible_from: eligibleFrom, reason: reason.trim(), acknowledge_default_withholding: acknowledged } : {}),
      });
      if (scopeRef.current === scope) onUpdated(response.data);
    } catch (caught) {
      if (scopeRef.current === scope) setError(caught instanceof Error ? caught.message : 'Could not save intake review.');
    } finally {
      if (scopeRef.current === scope) setSaving(false);
    }
  };

  return (
    <section className="mb-6 rounded-xl border border-warning-200 bg-warning-50 p-4 sm:p-5" aria-label="Incomplete employee follow-up">
      <h2 className="font-semibold text-neutral-900">{readiness.profile_incomplete ? 'Profile incomplete' : 'Employee profile completed'}</h2>
      <p className="mt-1 text-sm leading-6 text-neutral-700">{exception.reason} Authorized by {exception.authorized_by_name || 'an administrator'}. Follow-up: {exception.follow_up_owner_name || 'Unassigned'}{exception.follow_up_due_on ? `, due ${formatDate(exception.follow_up_due_on)}` : ''}.</p>
      {readiness.missing_fields.length > 0 && <ul className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm text-warning-900">{readiness.missing_fields.map((field) => <li key={field}>{intakeFieldLabels[field] || field}</li>)}</ul>}
      <p className="mt-3 text-sm leading-6 text-neutral-700">Update the employee as details arrive. Missing address lines are omitted from checks; filing readiness still requires the missing filing details.</p>
      {exception.payroll_setup_confirmed_at ? (
        <p className="mt-2 text-sm font-medium text-neutral-800">Payroll setup reviewed by {exception.payroll_setup_confirmed_by_name || 'a manager'} on {formatGuamDateTime(exception.payroll_setup_confirmed_at)}. Earliest payroll participation: {formatDate(exception.payroll_eligible_from || employee.hire_date || '')}. Required documents must still be verified or explicitly waived.</p>
      ) : <p className="mt-2 text-sm font-semibold text-warning-900">Payroll setup needs manager review before this employee can be included in an approved payroll.</p>}
      {canReview && (
        <div className="mt-4 space-y-3 border-t border-warning-200 pt-4">
          <div className="flex flex-wrap items-end gap-3">
            <label className="text-sm font-medium text-neutral-700">Follow-up due date<Input type="date" value={dueOn} onChange={(event) => setDueOn(event.target.value)} /></label>
            <Button variant="outline" disabled={saving || !dueOn} onClick={() => void save(false)}>Save follow-up date</Button>
          </div>
          {!exception.payroll_setup_confirmed_at && (
            <>
              <label className="block max-w-xs text-sm font-medium text-neutral-700">Earliest payroll participation date<Input type="date" value={eligibleFrom} onChange={(event) => setEligibleFrom(event.target.value)} /></label>
              <label className="block text-sm font-medium text-neutral-700">Payroll setup review reason<Input value={reason} maxLength={500} onChange={(event) => setReason(event.target.value)} placeholder="Confirm worker classification, pay basis, rate, and intended payroll participation" /></label>
              {missingWithholding && <label className="flex items-start gap-2 text-sm leading-6 text-neutral-700"><input type="checkbox" className="mt-1 h-4 w-4" checked={acknowledged} onChange={(event) => setAcknowledged(event.target.checked)} />I authorize the default withholding treatment: single, no credits or adjustments. This records an approved fallback; the employee withholding election remains outstanding.</label>}
              <Button disabled={saving || !reason.trim() || !eligibleFrom || (missingWithholding && !acknowledged)} onClick={() => void save(true)}>{saving ? 'Recording review…' : 'Confirm payroll setup'}</Button>
              <p className="text-xs leading-5 text-neutral-600">This review does not waive documents or authorize a payment. Review each pay run before approval.</p>
            </>
          )}
        </div>
      )}
      {error && <ActionFeedback tone="error" message={error} />}
    </section>
  );
}
