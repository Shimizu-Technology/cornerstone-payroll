

import { Button } from '@/components/ui/button';

import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';

import type { PayRunSectionProps } from './usePayRunController';

export function RefreshSetupDialog({
  error,
  handleRefreshSetup,
  processing,
  refreshBaseSalary,
  refreshRecurring,
  refreshSetupOpen,
  setRefreshBaseSalary,
  setRefreshRecurring,
  setRefreshSetupOpen,
  sourceCoverageOpen
}: PayRunSectionProps<'refreshDialog'>) {
  return (<>
{refreshSetupOpen && !sourceCoverageOpen && (
          <Dialog open onOpenChange={open => { if (!processing) setRefreshSetupOpen(open); }}>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Refresh current setup</DialogTitle>
                <DialogDescription>
                  Apply current employee and client setup to the saved payroll. Hours, selected employees,
                  and manual overrides are preserved. Existing approval and client review will be withdrawn;
                  review and approve the new calculation.
                </DialogDescription>
              </DialogHeader>
              <div className="space-y-3">
                <label className="flex min-h-11 items-center gap-3">
                  <input type="checkbox" checked={refreshRecurring} onChange={event => setRefreshRecurring(event.target.checked)} disabled={processing} />
                  Include recurring employee setup
                </label>
                <p className="text-xs text-neutral-600">
                  Includes configured deductions and recurring additions. For only one saved loan,
                  use Linked loan repayments in the worksheet instead.
                </p>
                <label className="flex min-h-11 items-center gap-3">
                  <input type="checkbox" checked={refreshBaseSalary} onChange={event => setRefreshBaseSalary(event.target.checked)} disabled={processing} />
                  Include ordinary base salary
                </label>
                {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
              </div>
              <DialogFooter>
                <Button variant="outline" disabled={processing} onClick={() => setRefreshSetupOpen(false)}>Cancel</Button>
                <Button disabled={processing} onClick={() => void handleRefreshSetup()}>{processing ? 'Refreshing…' : 'Refresh and recalculate'}</Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
  </>);
}
