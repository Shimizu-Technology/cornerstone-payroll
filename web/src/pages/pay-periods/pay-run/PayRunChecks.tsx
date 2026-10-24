

import { Link } from 'react-router';

import { Button } from '@/components/ui/button';

import { Card } from '@/components/ui/card';

import { ChecksPanel } from '@/components/payroll/ChecksPanel';

import { payRunPath } from '@/lib/routes';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunChecks({
  checkPrintRefreshToken,
  companyId,
  isCommitted,
  loadPayPeriod,
  nonEmployeeChecks,
  paperCheckCount,
  payPeriod,
  returnTo,
  searchTerm,
  setCheckPrintOpen
}: PayRunSectionProps<'checks'>) {
  return (<>
{isCommitted && (
          <Card>
            <div className="p-4 border-b flex items-center justify-between gap-3">
              <h3 className="font-semibold text-neutral-900">Checks & direct deposit</h3>
              <div className="flex items-center gap-3">
                <Link to="/check-settings" className="text-xs text-blue-600 hover:underline">Check Settings ›</Link>
                <Button size="sm" onClick={() => setCheckPrintOpen(true)} disabled={paperCheckCount === 0 && !nonEmployeeChecks.some((check) => !check.voided)}>Print checks</Button>
              </div>
            </div>
            <div className="p-4">
              <ChecksPanel timeTrackingReviewHref={`${payRunPath(companyId, payPeriod.id, 'work', { returnTo })}#time-tracking-sync`} payPeriod={payPeriod} searchTerm={searchTerm} refreshToken={checkPrintRefreshToken} onChecksChanged={async () => {
                const result = await loadPayPeriod(payPeriod.id, true);
                if (result === 'failed') throw new Error('Saved checks could not refresh.');
              }} />
            </div>
          </Card>
        )}
  </>);
}
