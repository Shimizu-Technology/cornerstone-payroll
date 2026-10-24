

import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';

import { formatGuamDateTime } from '@/lib/utils';

import { runPurposeLabels } from './payRunSupport';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunMetadata({
  MAX_SYNC_ATTEMPTS,
  canRetrySyncTax,
  formatCorrectionPayDate,
  handleRetryTaxSync,
  isApproved,
  isCalculated,
  isCommitted,
  isCorrection,
  isVoided,
  payDateCorrections,
  payPeriod,
  processedBy,
  retryingSyncTax,
  statusConfig,
  syncConfig,
  syncStatus
}: PayRunSectionProps<'metadata'>) {
  return (<>
<div className="flex flex-wrap items-center gap-3">
          <Badge
            variant={
              isVoided ? 'danger' :
              isCommitted ? 'success' : isApproved ? 'info' : isCalculated ? 'warning' : 'default'
            }
          >
            {isVoided ? 'Voided' : statusConfig?.label || payPeriod.status}
          </Badge>
          {isCorrection && (
            <Badge variant="warning">Correction Run</Badge>
          )}
          <Badge variant={payPeriod.run_purpose === 'regular' ? 'default' : 'warning'}>
            {runPurposeLabels[payPeriod.run_purpose] || payPeriod.run_purpose}
          </Badge>
          {!payPeriod.includes_base_salary && <Badge variant="info">Base salary excluded</Badge>}
          {!payPeriod.includes_recurring_items && <Badge variant="info">Recurring setup excluded</Badge>}
          {isCommitted && payPeriod.committed_at && (
            <span className="text-sm text-neutral-600">
              Processed {formatGuamDateTime(payPeriod.committed_at)}
              {processedBy ? ` by ${processedBy}` : ''}
            </span>
          )}
          {isCommitted && syncConfig && (
            <>
              <Badge variant={syncConfig.variant}>
                {syncConfig.label}
              </Badge>
              {syncStatus === 'synced' && payPeriod.tax_synced_at && (
                <span className="text-sm text-neutral-600">
                  Synced {formatGuamDateTime(payPeriod.tax_synced_at)}
                </span>
              )}
              {syncStatus === 'failed' && payPeriod.tax_sync_last_error && (
                <span className="text-sm text-danger-600 max-w-md truncate" title={payPeriod.tax_sync_last_error}>
                  {payPeriod.tax_sync_last_error}
                </span>
              )}
              {canRetrySyncTax && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={handleRetryTaxSync}
                  disabled={retryingSyncTax}
                >
                  {retryingSyncTax ? 'Retrying...' : 'Retry Tax Sync'}
                </Button>
              )}
              {payPeriod.tax_sync_attempts != null && payPeriod.tax_sync_attempts > 0 && syncStatus !== 'synced' && (
                <span className="text-xs text-neutral-600">
                  Attempt {payPeriod.tax_sync_attempts}/{MAX_SYNC_ATTEMPTS}
                </span>
              )}
            </>
          )}
        </div>
{payDateCorrections.length > 0 && (
          <Card className="border-warning-200 bg-warning-50">
            <CardContent className="space-y-4 py-4">
              <div>
                <h3 className="text-base font-semibold text-warning-950">Pay Date Corrections</h3>
                <p className="mt-1 text-sm text-warning-800">
                  Date-only corrections made after this payroll was committed. Payroll dollar amounts were not changed.
                </p>
              </div>
              <div className="divide-y divide-warning-200 rounded-md border border-warning-200 bg-white/70">
                {payDateCorrections.map((correction) => (
                  <div key={correction.id} className="space-y-2 p-4">
                    <div className="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between">
                      <p className="text-sm font-medium text-neutral-900">
                        Pay date changed from {formatCorrectionPayDate(correction.old_pay_date)} to {formatCorrectionPayDate(correction.new_pay_date)}
                      </p>
                      <p className="text-xs text-neutral-600">
                        {formatGuamDateTime(correction.corrected_at)}
                        {correction.corrected_by_name ? ` by ${correction.corrected_by_name}` : ''}
                      </p>
                    </div>
                    <div>
                      <p className="text-xs font-medium text-warning-700">Reason</p>
                      <p className="mt-1 whitespace-pre-wrap text-sm text-neutral-700">
                        {correction.reason || 'No reason recorded'}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}
  </>);
}
