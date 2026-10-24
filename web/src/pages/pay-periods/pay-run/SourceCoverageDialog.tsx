

import { Button } from '@/components/ui/button';

import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';

import { Textarea } from '@/components/ui/textarea';

import { type CoverageAcknowledgement } from './payRunSupport';

import type { PayRunSectionProps } from './usePayRunController';

export function SourceCoverageDialog({
  commitRouteGenerationRef,
  companyId,
  handleRefreshSetup,
  handleRunPayroll,
  payRunId,
  pendingCoverageActionRef,
  processing,
  setSourceCoverageAcknowledged,
  setSourceCoverageOpen,
  setSourceCoverageReason,
  sourceCoverageAcknowledged,
  sourceCoverageOpen,
  sourceCoverageReason
}: PayRunSectionProps<'coverage'>) {
  return (<>
<Dialog open={sourceCoverageOpen} onOpenChange={open => {
        setSourceCoverageOpen(open);
        if (!open) pendingCoverageActionRef.current = null;
      }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Calculate without time tracking hours?</DialogTitle>
            <DialogDescription>Hourly employees from time tracking will be missing unless their hours were entered manually. Review &amp; add hours first, or explain why this is a manual or salary-only run.</DialogDescription>
          </DialogHeader>
          <label className="block text-sm font-semibold text-neutral-700" htmlFor="source-coverage-reason">Reason for calculating without imported hours</label>
          <Textarea id="source-coverage-reason" maxLength={1000} value={sourceCoverageReason} onChange={event => setSourceCoverageReason(event.target.value)} />
          <label className="flex items-start gap-3 text-sm text-neutral-700"><input type="checkbox" checked={sourceCoverageAcknowledged} onChange={event => setSourceCoverageAcknowledged(event.target.checked)} className="mt-1" />I understand that hourly employees from time tracking will be missing unless entered manually.</label>
          <DialogFooter>
            <Button variant="outline" onClick={() => { pendingCoverageActionRef.current = null; setSourceCoverageOpen(false); }}>Cancel</Button>
            <Button disabled={!sourceCoverageAcknowledged || !sourceCoverageReason.trim() || processing} title={!sourceCoverageAcknowledged || !sourceCoverageReason.trim() ? 'Enter a reason and acknowledge the missing hours.' : undefined} onClick={() => {
              const pending = pendingCoverageActionRef.current;
              pendingCoverageActionRef.current = null;
              setSourceCoverageOpen(false);
              if (!pending || pending.companyId !== companyId || pending.payRunId !== payRunId || pending.generation !== commitRouteGenerationRef.current) return;
              const coverage: CoverageAcknowledgement = { source_coverage_reason: sourceCoverageReason.trim(), source_coverage_acknowledged: true };
              if (pending.action === 'refresh') void handleRefreshSetup(pending.refreshScope, coverage);
              else void handleRunPayroll(coverage);
            }}>Calculate without imported hours</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
  </>);
}
