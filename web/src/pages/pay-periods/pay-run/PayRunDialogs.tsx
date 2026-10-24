

import { Button } from '@/components/ui/button';

import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';

import { ImportModal } from '@/components/import/ImportModal';
import { PayrollIntakeImportModal } from '@/components/import/PayrollIntakeImportModal';

import { PayrollItemEditModal } from '@/components/payroll/PayrollItemEditModal';
import { CorrectivePaycheckModal } from '@/components/payroll/CorrectivePaycheckModal';
import { ReplaceCheckModal } from '@/components/payroll/ReplaceCheckModal';

import { TimeTrackingImportModal } from '@/components/payroll/TimeTrackingImportModal';
import { AirePayrollRecordsDialog } from '@/components/payroll/AirePayrollRecordsDialog';

import { PayrollCommitDialog } from '@/components/payroll/PayrollCommitDialog';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunDialogs({
  activeCompany,
  aireRecordsOpen,
  clientApprovalConfirmed,
  clientApprovalEvidence,
  clientApprovalLoading,
  clientApprovalNotes,
  clientApprovalOpen,
  clientApproverId,
  clientApprovers,
  commitPeriodId,
  companyId,
  correctingItem,
  editingItem,
  employeeLookup,
  employees,
  handleCommit,
  handleCorrectPayDate,
  handleImportComplete,
  handlePayrollItemSaved,
  importModalOpen,
  invalidateAireSource,
  isApproved,
  isVoided,
  linkedAireRecords,
  loadPayPeriod,
  loadSupplementals,
  payDateCorrectionDate,
  payDateCorrectionOpen,
  payDateCorrectionReason,
  payDateCorrectionSubmitting,
  payPeriod,
  payRunId,
  payrollIntakeImportOpen,
  payrollItems,
  processing,
  recordClientApproval,
  reloadSavedSourceImport,
  replacingItem,
  reportablePayrollItems,
  setAdditionalEmployeeIds,
  setAireRecordsOpen,
  setClientApprovalConfirmed,
  setClientApprovalEvidence,
  setClientApprovalNotes,
  setClientApprovalOpen,
  setClientApproverId,
  setCommitPeriodId,
  setCorrectingItem,
  setEditingItem,
  setEmployees,
  setHoursMap,
  setImportModalOpen,
  setPayDateCorrectionDate,
  setPayDateCorrectionOpen,
  setPayDateCorrectionReason,
  setPayPeriod,
  setPayrollIntakeImportOpen,
  setPayrollItems,
  setReplacingItem,
  setTimeTrackingAutoPreview,
  setTimeTrackingImportOpen,
  timeTrackingAutoPreview,
  timeTrackingImportOpen,
  totalNet
}: PayRunSectionProps<'dialogs'>) {
  return (<>
<ImportModal
        open={importModalOpen}
        onOpenChange={setImportModalOpen}
        payPeriodId={payPeriod.id}
        onSourcePreviewed={() => void loadPayPeriod(payPeriod.id, true)}
        onImportComplete={handleImportComplete}
      />
<PayrollIntakeImportModal
        open={payrollIntakeImportOpen}
        onOpenChange={setPayrollIntakeImportOpen}
        payPeriodId={payPeriod.id}
        employees={employees}
        onEmployeeCreated={(employee) => setEmployees((current) => [...current.filter((candidate) => candidate.id !== employee.id), employee])}
        onSourcePreviewed={() => void loadPayPeriod(payPeriod.id, true)}
        onImportComplete={handleImportComplete}
      />
<TimeTrackingImportModal
        key={`${payPeriod.company_id}-${payPeriod.id}`}
        open={timeTrackingImportOpen}
        onClose={() => {
          setTimeTrackingImportOpen(false);
          setTimeTrackingAutoPreview(false);
        }}
        payPeriod={payPeriod}
        employees={employees}
        onImportComplete={reloadSavedSourceImport}
        onCorrectionRecorded={() => {
          invalidateAireSource();
          void loadPayPeriod(payPeriod.id, true, true);
        }}
        initialSourceId={timeTrackingAutoPreview
          ? payPeriod.time_tracking?.aire_calendar?.source_id
          : undefined}
        autoPreview={timeTrackingAutoPreview}
      />
<AirePayrollRecordsDialog
        open={aireRecordsOpen}
        onClose={() => setAireRecordsOpen(false)}
        records={linkedAireRecords}
      />
{correctingItem && payPeriod && payPeriod.cycle !== 'supplemental' && (
        <CorrectivePaycheckModal
          open={correctingItem !== null}
          onOpenChange={(isOpen) => { if (!isOpen) setCorrectingItem(null); }}
          originalPayPeriod={payPeriod}
          originalItem={correctingItem}
          onIssued={() => {
            setCorrectingItem(null);
            // Refresh both the supplementals list and the parent period
            // (so totals/badges that depend on YTD or supplemental count
            // pick up the freshly committed corrective).
            loadSupplementals(payPeriod.id);
            loadPayPeriod(payPeriod.id, true);
          }}
        />
      )}
{replacingItem && payPeriod && payPeriod.cycle !== 'supplemental' && (
        <ReplaceCheckModal
          open={replacingItem !== null}
          onOpenChange={(isOpen) => { if (!isOpen) setReplacingItem(null); }}
          payPeriod={payPeriod}
          payrollItem={replacingItem}
          onReplaced={() => {
            setReplacingItem(null);
            loadPayPeriod(payPeriod.id, true);
          }}
        />
      )}
<PayrollItemEditModal
        open={editingItem !== null}
        onOpenChange={(isOpen) => { if (!isOpen) setEditingItem(null); }}
        payPeriodId={payPeriod.id}
        item={editingItem}
        onSaved={handlePayrollItemSaved}
        onRemoved={(id) => {
          const removedItem = payrollItems.find((item) => item.id === id);
          setPayrollItems((prev) => prev.filter((item) => item.id !== id));
          if (removedItem) {
            setPayPeriod((prev) => prev ? {
              ...prev,
              excluded_employee_ids: Array.from(new Set([...(prev.excluded_employee_ids || []), removedItem.employee_id])),
            } : prev);
            const employeeKey = String(removedItem.employee_id);
            setHoursMap((prev) => {
              const next = { ...prev };
              delete next[employeeKey];
              return next;
            });
            setAdditionalEmployeeIds((prev) => {
              const next = new Set(prev);
              next.delete(removedItem.employee_id);
              return next;
            });
          }
          setEditingItem(null);
          void loadPayPeriod(payPeriod.id, true);
        }}
        contractorPayType={editingItem ? employeeLookup.get(editingItem.employee_id)?.contractor_pay_type as 'hourly' | 'flat_fee' | undefined : undefined}
        wageRates={editingItem ? (employeeLookup.get(editingItem.employee_id)?.wage_rates || []) : []}
      />
<Dialog
        open={clientApprovalOpen}
        onOpenChange={(open) => {
          if (!clientApprovalLoading) setClientApprovalOpen(open);
        }}
      >
        <DialogContent>
          <form onSubmit={recordClientApproval}>
            <DialogHeader>
              <DialogTitle>Record Explicit Client Approval</DialogTitle>
              <DialogDescription>
                Use this only when an assigned client approver explicitly approved review revision {payPeriod.payroll_review?.revision}. Keep the source email or document in the client record.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              {clientApprovers.length === 0 ? (
                <div role="alert" className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900">
                  No active client portal user is assigned to this client. Add the authorized client contact in Users before recording approval.
                </div>
              ) : (
                <>
                  <div className="space-y-2">
                    <Label htmlFor="client_approver">Client approver</Label>
                    <Select id="client_approver" value={clientApproverId} onChange={(event) => setClientApproverId(event.target.value)} required>
                      {clientApprovers.map((approver) => <option key={approver.id} value={approver.id}>{approver.name} · {approver.email}</option>)}
                    </Select>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="client_approval_evidence">Retained email reference</Label>
                    <Input id="client_approval_evidence" value={clientApprovalEvidence} onChange={(event) => setClientApprovalEvidence(event.target.value)} placeholder="Gmail message ID, thread link, or client document reference" required maxLength={500} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="client_approval_notes">Notes (optional)</Label>
                    <Textarea id="client_approval_notes" value={clientApprovalNotes} onChange={(event) => setClientApprovalNotes(event.target.value)} placeholder="Anything the client asked Cornerstone to retain with this approval." maxLength={2000} />
                  </div>
                  <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-xs leading-6 text-neutral-600">
                    <input type="checkbox" className="mt-1 h-4 w-4 rounded border-neutral-300" checked={clientApprovalConfirmed} onChange={(event) => setClientApprovalConfirmed(event.target.checked)} />
                    <span>I verified that this client—not merely the Cornerstone recipient—explicitly wrote: “{payPeriod.payroll_review?.acknowledgement}” for review ID <span className="font-mono font-semibold">{payPeriod.payroll_review?.checksum_short}</span>. A reply such as “Received, thank you” is receipt only.</span>
                  </label>
                </>
              )}
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setClientApprovalOpen(false)} disabled={clientApprovalLoading}>Cancel</Button>
              <Button type="submit" disabled={clientApprovalLoading || clientApprovers.length === 0 || !clientApproverId || !clientApprovalEvidence.trim() || !clientApprovalConfirmed}>
                {clientApprovalLoading ? 'Recording…' : 'Bind Approval to This Revision'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
<PayrollCommitDialog open={commitPeriodId === payRunId && payPeriod.id === payRunId && isApproved && !isVoided}
        payPeriod={payPeriod} companyName={activeCompany && activeCompany.id === payPeriod.company_id ? activeCompany.name : `Company #${payPeriod.company_id || companyId}`}
        itemCount={reportablePayrollItems.length} totalNet={totalNet} processing={processing}
        onCancel={() => setCommitPeriodId(null)} onConfirm={confirmedPeriodId => void handleCommit(confirmedPeriodId)} />
<Dialog
        open={payDateCorrectionOpen}
        onOpenChange={(open) => {
          setPayDateCorrectionOpen(open);
          if (!open) {
            setPayDateCorrectionReason('');
            setPayDateCorrectionDate('');
          }
        }}
      >
        <DialogContent>
          <form onSubmit={handleCorrectPayDate}>
            <DialogHeader>
              <DialogTitle>Correct Committed Pay Date</DialogTitle>
              <DialogDescription>
                Use this only for a clerical pay date mistake after payroll was committed. Payroll amounts stay unchanged.
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="committed_pay_date">Pay Date</Label>
                <Input
                  id="committed_pay_date"
                  type="date"
                  value={payDateCorrectionDate}
                  onChange={(event) => setPayDateCorrectionDate(event.target.value)}
                  required
                />
                <p className="text-xs text-neutral-600">
                  This updates the committed pay period, matching check dates, pay stubs, reports, configured downstream sync payloads, and linked pay-period checks.
                </p>
              </div>
              <div className="space-y-2">
                <Label htmlFor="committed_pay_date_reason">Reason</Label>
                <Textarea
                  id="committed_pay_date_reason"
                  value={payDateCorrectionReason}
                  onChange={(event) => setPayDateCorrectionReason(event.target.value)}
                  placeholder="Example: Pay date was entered as April 15 but should be April 30."
                  required
                />
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setPayDateCorrectionOpen(false)}
                disabled={payDateCorrectionSubmitting}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={payDateCorrectionSubmitting}>
                {payDateCorrectionSubmitting ? 'Saving...' : 'Save Pay Date Correction'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
  </>);
}
