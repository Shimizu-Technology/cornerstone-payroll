import { useEffect, useId, useMemo, useState, type FormEvent } from 'react';
import { isReverificationCancelledError } from '@clerk/react/errors';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { useOptionalAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteCompany } from '@/lib/company-write-access';
import { formatDate, formatDateRange } from '@/lib/display-date';
import { useOptionalStepUpRequest } from '@/lib/useOptionalStepUpRequest';
import { stepUpErrorMessage } from '@/lib/useStepUpRequest';
import { staffEmployeeLifecycleApi, type ReadinessMutation, type ReadinessOptions, type ReadinessPreview, type ReadinessScope } from '@/services/staff-employee-lifecycle';
import { StaffReadinessChecklist } from './StaffReadinessChecklist';

type ReadinessAction = { type: 'grant' } | { type: 'clear' } | { type: 'revoke'; overrideId: number };

interface ReadinessActionsProps {
  companyId: number;
  employeeId: number;
  employeeName: string;
  payPeriodId?: number;
  disabled?: boolean;
  onUpdated: (action: ReadinessMutation['action']) => void;
}

export function ReadinessOverrideActions(props: ReadinessActionsProps) {
  const auth = useOptionalAuth();
  const { activeCompany, activeCompanyId } = useCompany();
  if (!auth?.hasCapability?.('override_employee_readiness') || activeCompanyId !== props.companyId
    || !activeCompany?.client_managed_employee_lifecycle || !canWriteCompany(activeCompany, 'override_employee_readiness')) return null;

  return <AuthorizedReadinessActions key={`${props.companyId}:${props.employeeId}:${props.payPeriodId ?? "profile"}`} {...props} />;
}

function AuthorizedReadinessActions({ companyId, employeeId, employeeName, payPeriodId, disabled, onUpdated }: ReadinessActionsProps) {
  const [action, setAction] = useState<ReadinessAction | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [options, setOptions] = useState<ReadinessOptions | null>(null);
  const [optionsError, setOptionsError] = useState('');
  const [notice, setNotice] = useState('');
  const loadOptions = !payPeriodId || action?.type === 'grant';

  useEffect(() => {
    if (!loadOptions) return;
    const controller = new AbortController();
    staffEmployeeLifecycleApi.readinessOptions(companyId, employeeId, controller.signal).then(
      response => { if (!controller.signal.aborted) setOptions(response.data); },
      (error: unknown) => { if (!controller.signal.aborted) setOptionsError(error instanceof Error ? error.message : 'Could not load readiness settings.'); },
    );
    return () => controller.abort();
  }, [companyId, employeeId, loadOptions, attempt]);

  return <div className="min-w-0 space-y-2">
    {!payPeriodId && notice && <p role="status" className="text-sm text-success-800">{notice}</p>}
    {!payPeriodId && optionsError && <Alert tone="error">{optionsError}</Alert>}
    <div className="flex flex-wrap gap-2">
      <Button className="min-h-11!" variant="outline" disabled={disabled} onClick={() => setAction({ type: 'grant' })}>Readiness override</Button>
      <Button className="min-h-11!" variant="outline" disabled={disabled} onClick={() => setAction({ type: 'clear' })}>Clear readiness gate</Button>
    </div>
    {!payPeriodId && options?.active_overrides.map(override => <div key={override.id} className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
      <Badge variant="warning">Override active</Badge>
      <span>{override.pay_period_id ? `Pay run #${override.pay_period_id}` : override.expires_on ? `Through ${formatDate(override.expires_on)}` : ''}</span>
      <Button className="min-h-11!" variant="ghost" disabled={disabled} onClick={() => setAction({ type: 'revoke', overrideId: override.id })}>Revoke override</Button>
    </div>)}
    {action && <ReadinessDialog {...{ companyId, employeeId, employeeName, payPeriodId, options, optionsError, action }}
      onReloadOptions={() => { setOptionsError(''); setAttempt(current => current + 1); }}
      onClose={() => setAction(null)}
      onSaved={() => {
        setNotice(action.type === 'grant' ? 'Payroll readiness override recorded.' : action.type === 'clear' ? 'Readiness gate cleared.' : 'Readiness override revoked.');
        setAction(null);
        setAttempt(current => current + 1);
        onUpdated(action.type);
      }} />}
  </div>;
}

function ReadinessDialog({ companyId, employeeId, employeeName, payPeriodId, options, optionsError, action, onReloadOptions, onClose, onSaved }: Omit<ReadinessActionsProps, 'onUpdated'> & {
  options: ReadinessOptions | null;
  optionsError: string;
  action: ReadinessAction;
  onReloadOptions: () => void;
  onClose: () => void;
  onSaved: () => void;
}) {
  const reasonId = useId();
  const [scopeType, setScopeType] = useState<'pay-period' | 'expiration'>('pay-period');
  const [chosenPeriod, setChosenPeriod] = useState('');
  const [expiration, setExpiration] = useState('');
  const [reason, setReason] = useState('');
  const [acknowledged, setAcknowledged] = useState(false);
  const [busy, setBusy] = useState(false);
  const [submitError, setSubmitError] = useState('');
  const [previewAttempt, setPreviewAttempt] = useState(0);
  const [result, setResult] = useState<{ scope: ReadinessScope; data?: ReadinessPreview; error?: string } | null>(null);
  const grant = action.type === 'grant';
  const targetPeriod = chosenPeriod || (payPeriodId ? String(payPeriodId) : String(options?.pay_periods[0]?.id ?? ''));
  const scope = useMemo<ReadinessScope | null>(() => {
    if (!grant || !options) return null;
    if (scopeType === 'pay-period') return targetPeriod ? { pay_period_id: Number(targetPeriod) } : null;
    return expiration && expiration >= options.today && expiration <= options.latest_expiration ? { expires_on: expiration } : null;
  }, [grant, options, scopeType, targetPeriod, expiration]);
  const preview = result?.scope === scope ? result?.data : undefined;
  const previewError = result?.scope === scope ? result?.error : undefined;
  const requiresAcknowledgement = preview?.default_w4_acknowledgement_required === true;

  useEffect(() => {
    if (!scope) return;
    const controller = new AbortController();
    staffEmployeeLifecycleApi.readinessPreview(companyId, employeeId, scope, controller.signal).then(
      response => { if (!controller.signal.aborted) setResult({ scope, data: response.data }); },
      (error: unknown) => { if (!controller.signal.aborted) setResult({ scope, error: error instanceof Error ? error.message : 'Could not check payroll readiness.' }); },
    );
    return () => controller.abort();
  }, [scope, previewAttempt, companyId, employeeId]);

  const send = useOptionalStepUpRequest(staffEmployeeLifecycleApi.changeReadiness);
  const canSubmit = !busy && reason.trim().length >= 10 && (!grant || (
    Boolean(preview?.checklist.missing_keys.length) && (!requiresAcknowledgement || acknowledged)
  ));
  const title = grant ? 'Readiness override' : action.type === 'clear' ? 'Clear readiness gate' : 'Revoke readiness override';

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!canSubmit) return;
    const text = reason.trim();
    let mutation: ReadinessMutation;
    if (action.type === 'grant') {
      if (!scope) return;
      mutation = { action: 'grant', scope, reason: text, default_w4_acknowledged: requiresAcknowledgement && acknowledged };
    } else if (action.type === 'clear') mutation = { action: 'clear', reason: text };
    else mutation = { action: 'revoke', reason: text, overrideId: action.overrideId };
    setBusy(true);
    setSubmitError('');
    try {
      const response = await send(companyId, employeeId, mutation);
      if (!response.ok) throw new Error(stepUpErrorMessage(await response.json().catch(() => null), 'Could not save the readiness change.'));
      onSaved();
    } catch (error) {
      if (!isReverificationCancelledError(error)) setSubmitError(error instanceof Error ? error.message : 'Could not save the readiness change.');
    } finally {
      setBusy(false);
    }
  };

  return <Dialog open onOpenChange={open => { if (!open && !busy) onClose(); }}>
    <DialogContent>
      <DialogHeader>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription><span className="wrap-anywhere">{employeeName}.</span>{' '}
          {grant ? 'Allow payroll for the selected period or through an expiration date.'
            : action.type === 'clear' ? 'Payroll will stop blocking this employee for missing setup in future pay runs. Use this only when the readiness gate was applied in error.'
              : 'Payroll will check the employee’s setup again on uncommitted runs.'}
        </DialogDescription>
      </DialogHeader>
      <form onSubmit={submit} className="min-w-0 space-y-4">
        {grant && <>
          {optionsError && <Alert tone="error">{optionsError}<Button type="button" variant="outline" className="mt-2 block min-h-11!" onClick={onReloadOptions}>Try again</Button></Alert>}
          {!options && !optionsError && <p role="status" className="text-sm">Loading open pay periods…</p>}
          {options && <>
            <Select label="Override scope" className="h-11 text-base!" value={scopeType} disabled={busy} onChange={event => {
              setScopeType(event.target.value === 'expiration' ? 'expiration' : 'pay-period');
              setAcknowledged(false);
            }}>
              <option value="pay-period">One pay period</option>
              <option value="expiration">Through an expiration date</option>
            </Select>
            {scopeType === 'pay-period' ? <Select label="Pay period" className="h-11 text-base!" value={targetPeriod} required disabled={busy} onChange={event => {
              setChosenPeriod(event.target.value);
              setAcknowledged(false);
            }}>
              {!options.pay_periods.length && <option value="">No open pay periods</option>}
              {options.pay_periods.map(period => <option key={period.id} value={period.id}>#{period.id} · {formatDateRange(period.start_date, period.end_date)} · Pay {formatDate(period.pay_date)}</option>)}
            </Select> : <Input label="Expiration date (up to 30 days)" type="date" min={options.today} max={options.latest_expiration} className="h-11 text-base!"
              required value={expiration} disabled={busy} onChange={event => { setExpiration(event.target.value); setAcknowledged(false); }} />}
            {scope && !preview && !previewError && <p role="status" className="text-sm">Checking payroll readiness…</p>}
            {previewError && <Alert tone="error">{previewError}<Button type="button" variant="outline" className="mt-2 block min-h-11!" onClick={() => {
              setResult(null);
              setPreviewAttempt(current => current + 1);
            }}>Check again</Button></Alert>}
            {preview && <StaffReadinessChecklist checklist={preview.checklist} missingOnly />}
            {requiresAcknowledgement && <label className="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-950">
              <input type="checkbox" className="mt-0.5 size-5 shrink-0" required checked={acknowledged} disabled={busy} onChange={event => setAcknowledged(event.target.checked)} />
              <span>I acknowledge that federal/Guam income tax will be withheld at Single with no adjustments (IRS Pub 15-T default) until a signed Form W-4 is recorded.</span>
            </label>}
          </>}
        </>}
        <div className="space-y-2">
          <label htmlFor={reasonId} className="block text-sm font-medium">Reason (10–1,000 characters)</label>
          <Textarea id={reasonId} className="text-base!" value={reason} required maxLength={1000} disabled={busy} onChange={event => setReason(event.target.value)} />
        </div>
        <p className="text-sm text-neutral-600">You may be asked to verify your sign-in before this change is saved.</p>
        {submitError && <Alert tone="error">{submitError}</Alert>}
        <DialogFooter>
          <Button type="button" className="min-h-11!" variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button type="submit" className="min-h-11!" disabled={!canSubmit}>{busy ? 'Saving…' : grant ? 'Allow in payroll' : title}</Button>
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>;
}
