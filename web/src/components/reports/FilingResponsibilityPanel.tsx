import { useState } from 'react';
import { AlertTriangle, CheckCircle2, ClipboardCheck, Database, PencilLine } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { reportsApi } from '@/services/api';
import type {
  PayrollFilingGate,
  PayrollFilingGateGroup,
  PayrollFilingType,
} from '@/types';

const FILING_LABELS: Record<PayrollFilingType, string> = {
  form_941: 'Federal Form 941',
  guam_withholding: 'Guam withholding (Form 500 / W-1)',
  swica: 'SWICA wage report',
  w2_gu: 'W-2GU annual filing',
};

function filingStatus(gate: PayrollFilingGate) {
  switch (gate.status) {
    case 'cornerstone_responsible':
      return { label: 'Cornerstone responsible', variant: 'success' as const };
    case 'external_provider_responsible':
      return { label: 'External provider', variant: 'warning' as const };
    case 'responsibility_required':
      return { label: 'Review required', variant: 'danger' as const };
    case 'historical_payroll_excluded':
      return { label: 'Imported payroll excluded', variant: 'danger' as const };
    case 'review_stale':
      return { label: 'Review again', variant: 'danger' as const };
    default:
      return { label: 'No migration review needed', variant: 'outline' as const };
  }
}

function formatReviewDate(value: string | null | undefined) {
  if (!value) return null;
  return new Date(value).toLocaleString();
}

interface FilingResponsibilityPanelProps {
  gate: PayrollFilingGateGroup;
  canRecord: boolean;
  onUpdated: (gate: PayrollFilingGateGroup) => void;
}

export function FilingResponsibilityPanel({ gate, canRecord, onUpdated }: FilingResponsibilityPanelProps) {
  const [editing, setEditing] = useState<PayrollFilingType | null>(null);
  const [responsibleParty, setResponsibleParty] = useState<'cornerstone' | 'external_provider'>('cornerstone');
  const [importedInclusion, setImportedInclusion] = useState<'included' | 'excluded'>('included');
  const [sourceCutoffDate, setSourceCutoffDate] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const filings = Object.entries(gate.filings) as [PayrollFilingType, PayrollFilingGate][];
  const coverage = gate.source_coverage;
  const hasHistorical = coverage.has_historical_payroll;

  function beginReview(filingType: PayrollFilingType, filing: PayrollFilingGate) {
    const decision = filing.responsibility;
    setEditing(filingType);
    setResponsibleParty(decision?.responsible_party ?? 'cornerstone');
    setImportedInclusion(decision?.imported_payroll_inclusion ?? 'included');
    setSourceCutoffDate(decision?.source_cutoff_date ?? '');
    setNotes(decision?.notes ?? '');
    setError(null);
  }

  async function saveReview() {
    if (!editing) return;
    setSaving(true);
    setError(null);
    try {
      const response = await reportsApi.updatePayrollFilingResponsibility({
        tax_year: gate.tax_year,
        quarter: gate.quarter ?? undefined,
        filing_types: [editing],
        responsible_party: responsibleParty,
        imported_payroll_inclusion: importedInclusion,
        source_cutoff_date: sourceCutoffDate || undefined,
        notes: notes.trim() || undefined,
      });
      onUpdated(response.filing_gate);
      setEditing(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to save the filing responsibility review.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <CardTitle className="flex items-center gap-2 text-base">
              <ClipboardCheck className="h-4 w-4 text-primary-700" aria-hidden="true" />
              Filing source responsibility
            </CardTitle>
            <CardDescription className="mt-1 max-w-3xl">
              Record who owns each filing and whether locked QuickBooks payroll is included. This review never changes imported payroll amounts.
            </CardDescription>
          </div>
          <Badge variant={gate.blockers.length === 0 ? 'success' : 'warning'}>
            {gate.blockers.length === 0 ? 'Source review complete' : `${gate.blockers.length} source review${gate.blockers.length === 1 ? '' : 's'} needed`}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap items-center gap-x-5 gap-y-2 rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3 text-sm text-neutral-700">
          <span className="flex items-center gap-2 font-medium text-neutral-900">
            <Database className="h-4 w-4 text-neutral-500" aria-hidden="true" />
            Pay-date source coverage
          </span>
          <span>{coverage.historical_pay_period_count} locked QuickBooks period{coverage.historical_pay_period_count === 1 ? '' : 's'}</span>
          <span>{coverage.native_pay_period_count} Cornerstone period{coverage.native_pay_period_count === 1 ? '' : 's'}</span>
          {coverage.mixed_sources && <Badge variant="info">Mixed sources</Badge>}
        </div>

        {!hasHistorical && filings.every(([, filing]) => !filing.decision_recorded) ? (
          <div className="flex items-start gap-3 rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-700">
            <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <p>No locked imported payroll falls in this filing period, so a migration responsibility decision is not required.</p>
          </div>
        ) : (
          <div className="divide-y divide-neutral-200 rounded-xl border border-neutral-200">
            {filings.map(([filingType, filing]) => {
              const status = filingStatus(filing);
              const decision = filing.responsibility;
              const isEditing = editing === filingType;

              return (
                <div key={filingType} className="p-4">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="font-semibold text-neutral-950">{FILING_LABELS[filingType]}</p>
                        <Badge variant={status.variant}>{status.label}</Badge>
                      </div>
                      {decision ? (
                        <p className="mt-1 text-xs text-neutral-500">
                          Reviewed by {decision.reviewed_by.name} · {formatReviewDate(decision.reviewed_at)}
                          {decision.source_cutoff_date ? ` · Source cutoff ${decision.source_cutoff_date}` : ''}
                        </p>
                      ) : (
                        <p className="mt-1 text-sm text-neutral-600">Confirm who will file and how imported wages will be handled.</p>
                      )}
                      {filing.blockers.map((blocker) => (
                        <div key={blocker.code} className="mt-2 flex items-start gap-2 text-sm text-amber-800">
                          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                          <span>{blocker.message}</span>
                        </div>
                      ))}
                    </div>
                    {canRecord && !isEditing && (
                      <Button variant="outline" size="sm" onClick={() => beginReview(filingType, filing)}>
                        <PencilLine className="mr-2 h-4 w-4" aria-hidden="true" />
                        {decision ? 'Review again' : 'Record review'}
                      </Button>
                    )}
                  </div>

                  {isEditing && (
                    <div className="mt-4 rounded-xl border border-primary-200 bg-primary-50/40 p-4">
                      <div className="grid gap-4 md:grid-cols-2">
                        <label className="text-sm font-medium text-neutral-800">
                          Who is responsible for filing?
                          <select
                            value={responsibleParty}
                            onChange={(event) => setResponsibleParty(event.target.value as typeof responsibleParty)}
                            disabled={saving}
                            className="mt-1.5 h-10 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-950 focus:outline-none focus:ring-2 focus:ring-primary-300"
                          >
                            <option value="cornerstone">Cornerstone</option>
                            <option value="external_provider">External payroll provider</option>
                          </select>
                        </label>
                        <label className="text-sm font-medium text-neutral-800">
                          Imported payroll in this filing
                          <select
                            value={importedInclusion}
                            onChange={(event) => setImportedInclusion(event.target.value as typeof importedInclusion)}
                            disabled={saving}
                            className="mt-1.5 h-10 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-950 focus:outline-none focus:ring-2 focus:ring-primary-300"
                          >
                            <option value="included">Included</option>
                            <option value="excluded">Excluded</option>
                          </select>
                        </label>
                        <label className="text-sm font-medium text-neutral-800">
                          Source cutoff date <span className="font-normal text-neutral-500">(optional)</span>
                          <input
                            type="date"
                            value={sourceCutoffDate}
                            onChange={(event) => setSourceCutoffDate(event.target.value)}
                            disabled={saving}
                            className="mt-1.5 h-10 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-950 focus:outline-none focus:ring-2 focus:ring-primary-300"
                          />
                        </label>
                        <label className="text-sm font-medium text-neutral-800">
                          Review notes <span className="font-normal text-neutral-500">(optional)</span>
                          <input
                            value={notes}
                            onChange={(event) => setNotes(event.target.value)}
                            disabled={saving}
                            maxLength={2000}
                            placeholder="Provider, confirmation, or exception details"
                            className="mt-1.5 h-10 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-950 focus:outline-none focus:ring-2 focus:ring-primary-300"
                          />
                        </label>
                      </div>
                      {responsibleParty === 'cornerstone' && importedInclusion === 'excluded' && hasHistorical && (
                        <div className="mt-3 flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                          Cornerstone filing-ready actions will stay blocked because locked imported payroll is inside this filing period.
                        </div>
                      )}
                      {responsibleParty === 'external_provider' && (
                        <p className="mt-3 text-sm text-neutral-600">Cornerstone reports will remain draft/reference copies because the external provider owns this filing.</p>
                      )}
                      {error && <p className="mt-3 text-sm text-danger-600" role="alert">{error}</p>}
                      <div className="mt-4 flex flex-wrap gap-2">
                        <Button size="sm" onClick={saveReview} disabled={saving}>
                          {saving ? 'Saving…' : 'Save responsibility'}
                        </Button>
                        <Button variant="ghost" size="sm" onClick={() => setEditing(null)} disabled={saving}>Cancel</Button>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {!canRecord && hasHistorical && (
          <p className="text-xs text-neutral-500">You can review this decision, but your role cannot change filing responsibility.</p>
        )}
      </CardContent>
    </Card>
  );
}
