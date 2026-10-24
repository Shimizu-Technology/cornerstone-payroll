

import { UnifiedCheckPrintDialog } from '@/components/checks/UnifiedCheckPrintDialog';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunCheckPrintDialog({
  checkPrintOpen,
  isCommitted,
  loadPayPeriod,
  payPeriod,
  setCheckPrintOpen,
  setCheckPrintRefreshToken
}: PayRunSectionProps<'printDialog'>) {
  return (<>
{isCommitted && (
          <UnifiedCheckPrintDialog
            open={checkPrintOpen}
            payPeriodId={payPeriod.id}
            onOpenChange={setCheckPrintOpen}
            onPackageGenerated={() => {
              setCheckPrintRefreshToken((value) => value + 1);
              void loadPayPeriod(payPeriod.id, true);
            }}
          />
        )}
  </>);
}
