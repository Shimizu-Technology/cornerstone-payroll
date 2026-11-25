import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { formatEmployeeAppDate, type PrintedInvite } from '@/services/employee-app-rollout-api';
import './printed-invites.css';

export function PrintedInvites({ invites, companyName, onClose }: {
  invites: PrintedInvite[];
  companyName: string;
  onClose: () => void;
}) {
  if (!invites.length) return null;

  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="employee-code-dialog max-h-[90dvh] overflow-y-auto">
        <DialogHeader className="print:hidden">
          <DialogTitle>Print sign-up {invites.length === 1 ? 'code' : 'codes'}</DialogTitle>
          <DialogDescription>Print before closing. You can only see these codes now. Hand each sheet directly to the employee it names.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3 print:space-y-0">
          {invites.map((invite) => (
            <article key={invite.code} className="employee-code-sheet space-y-2 rounded-xl border border-neutral-200 p-4 print:rounded-none print:border-0">
              <p className="text-sm text-neutral-700 [overflow-wrap:anywhere]">{companyName} · Employee app</p>
              <h3 className="text-lg font-semibold [overflow-wrap:anywhere]">{invite.name}</h3>
              <p className="text-sm">Open <strong className="[overflow-wrap:anywhere]">{invite.url}</strong> and enter this one-time code.</p>
              <p className="font-mono text-xl font-bold tracking-wider">{invite.code.slice(0, 5)}-{invite.code.slice(5)}</p>
              <p className="text-sm">Have your date of birth and the last four digits of your Social Security number ready.</p>
              <p className="text-sm">Use this code by {formatEmployeeAppDate(invite.expires_at, true)} (Guam time).</p>
            </article>
          ))}
        </div>
        <DialogFooter className="print:hidden">
          <Button type="button" variant="outline" onClick={onClose}>Done</Button>
          <Button type="button" onClick={() => window.print()}>Print {invites.length === 1 ? 'code' : 'codes'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
