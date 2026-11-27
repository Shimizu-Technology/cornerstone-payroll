import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { Link } from 'react-router';
import { Fragment, useEffect, useState, useRef, type ReactElement } from 'react';
import { CheckCircle2, ChevronDown, CircleDashed, Download, Info, RefreshCw } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { BusyStatus } from '@/components/ui/busy-status';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { changeSummary } from '@/lib/payrollSubmissionFormat';
import { computeExtraHoursPreview, formatCompactHours, parseDecimalHundredths, type ExtraHoursMode } from '@/lib/extraHoursPreview';
import { cn, formatCurrency, formatGuamDateTime } from '@/lib/utils';
import { acceptMapForDescriptor, carryRowOutcomes, defaultDisposition, fileSha256, importSourceFiles, noticeTitle, pickersForDescriptor, sameSourceFiles } from '@/lib/importSources';
import { EmployeeStatusTransitionDialog } from '@/components/employees/EmployeeStatusTransitionDialog';
import { ImportSourcePanel } from './ImportSourcePanel';
import { ImportSourceChecklist } from './ImportSourceChecklist';
import { InstallmentLoanSetup, type InstallmentLoanSubmission } from './InstallmentLoanSetup';
import { ApiError, employeesApi, payrollIntakeImportsApi, payPeriodsApi, payrollItemsApi } from '@/services/api';
import type { ImportPreviewResponse, ImportPreviewRow, MosaSourceRow, PayrollIntakeDescriptor, PayrollIntakeImportData } from '@/services/api';
import type { Employee, PayPeriod, PayrollItem } from '@/types';

interface ImportModalProps {
  initialPreview?: ImportPreviewResponse;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  companyId: number;
  descriptor?: PayrollIntakeDescriptor | null;
  onSourcePreviewed?: () => void;
  onImportComplete: (payPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => void;
  // Payroll staff can reactivate a matched inactive worker from the review.
  canReactivateWorkers?: boolean;
  // A terminated match is a rehire, which also needs client configuration.
  canRehireWorkers?: boolean;
}

type Step = 'upload' | 'preview' | 'applying' | 'done';
type EditableSourceRow = MosaSourceRow;
const SUPPORTED_REVIEWED_IMPORT_ROLES = new Set(['revel_hours', 'supplemental_workbook']);

export function ImportModal({ initialPreview, open, onOpenChange, payPeriodId, companyId, descriptor, onSourcePreviewed, onImportComplete, canReactivateWorkers = false, canRehireWorkers = false }: ImportModalProps) {
  const activeSourceType = descriptor?.key || 'mosa_revel';
  const sourcePickers = pickersForDescriptor(descriptor);
  const acceptByRole = acceptMapForDescriptor(descriptor);
  const defaultTipsPaidOut = descriptor?.tips_default === 'already_paid_out';
  const [step, setStep] = useState<Step>(initialPreview ? 'preview' : 'upload');
  const [pdfFile, setPdfFile] = useState<File | null>(null);
  const [excelFile, setExcelFile] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [previewData, setPreviewData] = useState<ImportPreviewResponse | null>(initialPreview || null);
  const [sourceRows, setSourceRows] = useState<EditableSourceRow[]>(() => initialPreview?.preview.source_rows.map(row => ({ ...row, disposition: row.row_kind === 'matched' && row.errors.length === 0 ? 'included' : 'pending' })) || []);
  const [rateChoices, setRateChoices] = useState<Record<string, number>>({});
  const [tipsPaidOutFromTips, setTipsPaidOutFromTips] = useState(defaultTipsPaidOut);
  const [reviewedClientChanges, setReviewedClientChanges] = useState(false);
  const [clientChangeDrafts, setClientChangeDrafts] = useState<Record<number, string>>({});
  const [clientExtraRegularDrafts, setClientExtraRegularDrafts] = useState<Record<number, string>>({});
  const [clientExtraOvertimeDrafts, setClientExtraOvertimeDrafts] = useState<Record<number, string>>({});
  const [clientExtraWorkweeks, setClientExtraWorkweeks] = useState<Record<number, number>>({});
  const [clientDeclines, setClientDeclines] = useState<Record<number, boolean>>({});
  const [clientAdjustmentReasons, setClientAdjustmentReasons] = useState<Record<number, string>>({});
  const [clientDeclineReasons, setClientDeclineReasons] = useState<Record<number, string>>({});
  const [clientPayChoices, setClientPayChoices] = useState<Record<number, string>>({});
  const [usePendingRevision, setUsePendingRevision] = useState(false);
  const [duplicateRevision, setDuplicateRevision] = useState<{ id: number; revision: number } | null>(null);
  const [staffWorkbook, setStaffWorkbook] = useState<File | null>(null);
  const [reviewedSuggestedMatches, setReviewedSuggestedMatches] = useState(false);
  const [reviewedOverwrite, setReviewedOverwrite] = useState(false);
  const [confirmHoursOverwrite, setConfirmHoursOverwrite] = useState(false);
  const [noTipsOrLoans, setNoTipsOrLoans] = useState(false);
  const [addingSource, setAddingSource] = useState(false);
  const [reactivating, setReactivating] = useState<Employee | null>(null);
  const [openingWorker, setOpeningWorker] = useState<number | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [savingTips, setSavingTips] = useState(false);
  // Fingerprints of the chosen files, to spot files the open import already holds.
  const [chosenDigests, setChosenDigests] = useState<Record<string, { file: File; sha256: string | null }>>({});
  const [results, setResults] = useState<{ success: number; errors: string[] } | null>(null);
  const [templateDownloading, setTemplateDownloading] = useState(false);
  const [currentPackage, setCurrentPackage] = useState<PayrollIntakeImportData | null>(null);
  const [replacementReason, setReplacementReason] = useState('');
  const [ownerPayDrafts, setOwnerPayDrafts] = useState<Record<number, number | null>>({});
  const [ownerPayBusy, setOwnerPayBusy] = useState<number | null>(null);
  const [ownerPayError, setOwnerPayError] = useState<string | null>(null);
  // Pay was saved but the review did not reload; offer a reload without saving again.
  const [reviewReloadNeeded, setReviewReloadNeeded] = useState(false);
  const reviewRef = useRef<HTMLDivElement>(null);
  const nextAttentionRow = useRef(0);
  const pdfInputRef = useRef<HTMLInputElement>(null);
  const excelInputRef = useRef<HTMLInputElement>(null);
  // Bumped when the review closes, so a save that finishes later is ignored.
  const reviewGeneration = useRef(0);

  const reset = () => {
    reviewGeneration.current += 1;
    setStep('upload');
    setUsePendingRevision(false); setStaffWorkbook(null);
    setReviewedClientChanges(false); setClientChangeDrafts({}); setClientExtraRegularDrafts({}); setClientExtraOvertimeDrafts({}); setClientExtraWorkweeks({}); setClientAdjustmentReasons({}); setClientDeclines({}); setClientDeclineReasons({}); setClientPayChoices({});
    setDuplicateRevision(null);
    setPdfFile(null);
    setExcelFile(null);
    setLoading(false);
    setError(null);
    setPreviewData(null);
    setSourceRows([]);
    setRateChoices({});
    setTipsPaidOutFromTips(defaultTipsPaidOut);
    setReviewedSuggestedMatches(false);
    setReviewedOverwrite(false);
    setConfirmHoursOverwrite(false);
    setNoTipsOrLoans(false);
    setAddingSource(false);
    setReactivating(null);
    setOpeningWorker(null);
    setNotice(null);
    setSavingTips(false);
    setChosenDigests({});
    setResults(null);
    setTemplateDownloading(false);
    setCurrentPackage(null);
    setReplacementReason('');
    setOwnerPayDrafts({});
    setOwnerPayBusy(null);
    setOwnerPayError(null);
    setReviewReloadNeeded(false);
  };

  const refreshCurrentPackage = () => payrollIntakeImportsApi.list(payPeriodId).then((history) => {
    setCurrentPackage(history.imports.find((entry) => entry.source_type === activeSourceType && entry.current) || null);
  }).catch(() => undefined);

  useEffect(() => {
    if (!open) return;

    let active = true;
    payrollIntakeImportsApi.list(payPeriodId).then((response) => {
      if (!active) return;
      setCurrentPackage(response.imports.find((entry) => entry.source_type === activeSourceType && entry.current) || null);
    }).catch((err) => {
      if (active) setError(err instanceof Error ? err.message : 'Could not load retained source history');
    });
    return () => { active = false; };
  }, [open, payPeriodId, activeSourceType, setError]);

  useEffect(() => {
    let active = true;
    const chosen = [['revel_hours', pdfFile], ['supplemental_workbook', excelFile]] as const;
    chosen.forEach(([role, file]) => {
      if (!file) return;
      void fileSha256(file).then((sha256) => {
        if (active) setChosenDigests((current) => ({ ...current, [role]: { file, sha256 } }));
      });
    });
    return () => { active = false; };
  }, [pdfFile, excelFile]);

  const handleDownloadTemplate = async () => {
    try {
      setTemplateDownloading(true);
      setError(null);
      const blob = await payPeriodsApi.downloadSupplementalTemplate(payPeriodId);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = 'Cornerstone-payroll-changes.xlsx';
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download the change workbook');
    } finally {
      setTemplateDownloading(false);
    }
  };

  // keepPendingSubmissionId keeps the client revision staff selected, when the
  // new review still offers that same revision.
  const openPreview = (data: ImportPreviewResponse, keepOutcomesFrom?: MosaSourceRow[], keepPendingSubmissionId?: number) => {
    setPreviewData(data);
    setReviewedClientChanges(false); setClientChangeDrafts({}); setClientExtraRegularDrafts({}); setClientExtraOvertimeDrafts({}); setClientExtraWorkweeks({}); setClientAdjustmentReasons({}); setClientDeclines({}); setClientDeclineReasons({}); setClientPayChoices({});
    setUsePendingRevision(keepPendingSubmissionId !== undefined && data.pending_portal_source?.submission_id === keepPendingSubmissionId);
    setRateChoices({});
    setSourceRows(keepOutcomesFrom
      ? carryRowOutcomes(keepOutcomesFrom, data.preview.source_rows)
      : data.preview.source_rows.map((row) => ({ ...row, disposition: defaultDisposition(row) })));
    setTipsPaidOutFromTips(data.preview.tips_paid_out_from_tips);
    setReviewedSuggestedMatches(false);
    setReviewedOverwrite(false);
    setConfirmHoursOverwrite(false);
    setStep('preview');
  };

  const handleResumeCurrent = async () => {
    try {
      setLoading(true);
      setError(null);
      const sourceType = currentPackage?.source_type || descriptor?.key;
      openPreview(sourceType ? await payPeriodsApi.currentImport(payPeriodId, sourceType) : await payPeriodsApi.currentImport(payPeriodId));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not reopen the current MoSa import');
    } finally {
      setLoading(false);
    }
  };

  // Reload the saved review in place. Outcomes already chosen for each source row are kept.
  const reloadReview = async (expectedImportId: number, generation = reviewGeneration.current) => {
    if (generation !== reviewGeneration.current) return;
    const sourceType = previewData?.source_package.source_type;
    const data = sourceType
      ? await payPeriodsApi.currentImport(payPeriodId, sourceType)
      : await payPeriodsApi.currentImport(payPeriodId);
    if (generation !== reviewGeneration.current) return;
    if (data.import_id !== expectedImportId) {
      throw new Error('The saved review changed. Close this window and open the submission again.');
    }
    setPreviewData(data);
    setUsePendingRevision(false);
    // Refreshed saved or workbook pay can differ from what staff confirmed.
    setReviewedClientChanges(false);
    setClientPayChoices({});
    // Merge into the latest rows, not the ones from when the save started, so
    // outcomes staff changed while the request was running are kept.
    setSourceRows((current) => {
      const chosen = new Map(current.map((row) => [row.id, row]));
      return data.preview.source_rows.map((row) => {
        const kept = chosen.get(row.id);
        return kept
          ? { ...row, disposition: kept.disposition, disposition_reason: kept.disposition_reason, target_pay_period_id: kept.target_pay_period_id }
          : { ...row, disposition: row.row_kind === 'matched' && row.errors.length === 0 ? 'included' : 'pending' };
      });
    });
    // The rows that need the replace-existing confirmation may have changed.
    setReviewedOverwrite(false);
    setConfirmHoursOverwrite(false);
  };

  // Each person's pay is saved on their own paycheck row, apart from calculation.
  const saveOwnerPay = async (row: ImportPreviewRow) => {
    const amount = ownerPayDrafts[row.employee_id];
    if (!previewData || !amount || amount <= 0) {
      setOwnerPayError(`Enter ${row.employee_name}’s pay for this period, greater than zero.`);
      return;
    }
    // Closing the review bumps the generation; a save that finishes later must not touch a reopened review.
    const generation = reviewGeneration.current;
    const stillOpen = () => generation === reviewGeneration.current;
    const importId = previewData.import_id;
    setOwnerPayBusy(row.employee_id);
    setOwnerPayError(null);
    setReviewReloadNeeded(false);
    let saved = false;
    try {
      const { payroll_items: items } = await payrollItemsApi.list(payPeriodId);
      if (!stillOpen()) return;
      const existing = items.find((item) => item.employee_id === row.employee_id);
      const guard = { expectedImportId: importId };
      if (existing) await payrollItemsApi.update(payPeriodId, existing.id, { salary_override: amount }, guard);
      else await payrollItemsApi.create(payPeriodId, { employee_id: row.employee_id, salary_override: amount }, guard);
      saved = true;
      if (!stillOpen()) return;
      await reloadReview(importId, generation);
      if (!stillOpen()) return;
      setOwnerPayDrafts((current) => ({ ...current, [row.employee_id]: null }));
    } catch (err) {
      if (!stillOpen()) return;
      const detail = err instanceof Error ? err.message : '';
      if (saved) {
        setOwnerPayDrafts((current) => ({ ...current, [row.employee_id]: null }));
        setOwnerPayError(`Pay for ${row.employee_name} was saved, but the review could not reload. ${detail}`.trim());
        setReviewReloadNeeded(true);
      } else {
        setOwnerPayError(`Could not save pay for ${row.employee_name}. ${detail}`.trim());
        // A refused stale save changed nothing; show the current amounts.
        if (err instanceof ApiError && err.status === 409) await reloadReview(importId, generation).catch(() => undefined);
      }
    } finally {
      if (stillOpen()) setOwnerPayBusy(null);
    }
  };

  const retryReviewReload = async () => {
    if (!previewData) return;
    try {
      await reloadReview(previewData.import_id);
      setReviewReloadNeeded(false);
      setOwnerPayError(null);
    } catch (err) {
      setOwnerPayError(`The review could not reload. ${err instanceof Error ? err.message : ''}`.trim());
    }
  };

  const ownerPayFeedback = ownerPayError && (
    <div role="alert" className="mt-3 space-y-2 font-medium text-danger-700">
      <p>{ownerPayError}</p>
      {reviewReloadNeeded && <Button type="button" variant="outline" size="sm" onClick={() => void retryReviewReload()}>Reload review</Button>}
    </div>
  );

  const handleClose = () => {
    if (loading || step === 'applying') return;
    reset();
    onOpenChange(false);
  };

  const handlePreview = async (submissionId?: number) => {
    if (!pdfFile && !excelFile) return;
    // The open import already holds exactly these files: reopen its review.
    if (!submissionId && reopensCurrent) {
      await handleResumeCurrent();
      return;
    }
    try {
      setLoading(true);
      setError(null);
      setReviewedSuggestedMatches(false);
      setReviewedOverwrite(false);
      // Files the open import already holds are kept by the server; send only the new ones.
      const send = (role: string, file: File | null) => (file && !(currentOpen && sameRoles.includes(role)) ? file : undefined);
      const data = await payPeriodsApi.previewImport(
        payPeriodId,
        send('revel_hours', pdfFile),
        send('supplemental_workbook', excelFile),
        tipsPaidOutFromTips,
        currentPackage && replacing
          ? { supersedesPackageId: currentPackage.package_id, reason: replacementReason.trim() }
          : undefined,
        submissionId,
        activeSourceType,
      );
      openPreview(data);
      setUsePendingRevision(!!submissionId);
      setDuplicateRevision(null);
      onSourcePreviewed?.();
      void refreshCurrentPackage();
    } catch (err) {
      const id = err instanceof ApiError ? err.details?.pending_submission_id : undefined;
      const revision = err instanceof ApiError ? err.details?.pending_revision : undefined;
      const duplicate = typeof id === 'number' && typeof revision === 'number' ? { id, revision } : null;
      setDuplicateRevision(duplicate);
      setError(duplicate ? null : err instanceof Error ? err.message : 'Failed to parse files');
      // Another upload may have changed the current package; show what it holds now.
      if (err instanceof ApiError && err.details?.replacement_required) void refreshCurrentPackage();
    } finally {
      setLoading(false);
    }
  };

  const startReactivation = async (employeeId: number) => {
    // Back or close while the worker loads must not open the dialog later.
    const generation = reviewGeneration.current;
    const stillOpen = () => generation === reviewGeneration.current;
    try {
      setOpeningWorker(employeeId);
      setError(null);
      const { data } = await employeesApi.get(employeeId, companyId);
      if (stillOpen()) setReactivating(data);
    } catch (err) {
      if (stillOpen()) setError(err instanceof Error ? err.message : 'Could not open this worker');
    } finally {
      if (stillOpen()) setOpeningWorker(null);
    }
  };

  // Match the same retained files again after the employee list or loans
  // changed. Outcomes already chosen for other rows are kept. The reason is
  // recorded on the new import version.
  const matchAgain = async (current: ImportPreviewResponse, reason: string, employeeId: number, readyStatus: string, attentionStatus: string, recordReason = true) => {
    const previousRows = sourceRows;
    const previousChoices = rateChoices;
    const previousDrafts = { clientChangeDrafts, clientExtraRegularDrafts, clientExtraOvertimeDrafts, clientExtraWorkweeks, clientDeclines, clientAdjustmentReasons, clientDeclineReasons, clientPayChoices };
    const previousPrefill = current.client_change_prefill || current.pending_change_prefill;
    const previousDocuments = current.source_package.documents;
    const pendingSubmissionId = usePendingRevision ? current.pending_portal_source?.submission_id : undefined;
    const portal = current.portal_source;
    const sourceType = current.source_package.source_type;
    const data = portal
      ? await payPeriodsApi.previewPortalSubmission(payPeriodId, portal.submission_id, {
          superseded_reason: portal.superseded_reason, supersedes_package_id: current.source_package.package_id,
          supersession_reason: reason, tips_paid_out_from_tips: current.preview.tips_paid_out_from_tips,
        })
      : recordReason
        ? (sourceType ? await payPeriodsApi.rematchImport(payPeriodId, reason, sourceType) : await payPeriodsApi.rematchImport(payPeriodId, reason))
        : (sourceType ? await payPeriodsApi.rematchImport(payPeriodId, undefined, sourceType) : await payPeriodsApi.rematchImport(payPeriodId));
    // Another window may have replaced the review with different files; outcomes
    // chosen here apply only to a review of the same files.
    const sameFiles = sameSourceFiles(previousDocuments, data.source_package.documents);
    openPreview(data, sameFiles ? previousRows : undefined, pendingSubmissionId);
    if (sameFiles) {
      // Keep job picks whose job is still offered, and the client-change drafts
      // when they are for the same client revision. Confirmations are asked again.
      setRateChoices(Object.fromEntries(Object.entries(previousChoices).filter(([employee, rateId]) => data.preview.matched
        .some((row) => String(row.employee_id) === employee && row.wage_rate_options?.some((option) => option.id === rateId)))));
      const prefill = data.client_change_prefill || data.pending_change_prefill;
      if (prefill && previousPrefill && prefill.submission_id === previousPrefill.submission_id && prefill.revision === previousPrefill.revision) {
        setClientChangeDrafts(previousDrafts.clientChangeDrafts);
        setClientExtraRegularDrafts(previousDrafts.clientExtraRegularDrafts);
        setClientExtraOvertimeDrafts(previousDrafts.clientExtraOvertimeDrafts);
        setClientExtraWorkweeks(previousDrafts.clientExtraWorkweeks);
        setClientDeclines(previousDrafts.clientDeclines);
        setClientAdjustmentReasons(previousDrafts.clientAdjustmentReasons);
        setClientDeclineReasons(previousDrafts.clientDeclineReasons);
        setClientPayChoices(previousDrafts.clientPayChoices);
      }
    }
    const ready = data.preview.source_rows.some((row) => row.employee_id === employeeId && row.row_kind === 'matched' && row.errors.length === 0);
    const status = ready ? readyStatus : attentionStatus;
    setNotice(sameFiles ? status : `${status} The import’s files changed since this review opened, so choose each row’s outcome again.`);
    onSourcePreviewed?.();
    void refreshCurrentPackage();
  };

  // After a worker returns, match the same retained files again so their row can be paid.
  const handleReactivated = async (employee: Employee) => {
    setReactivating(null);
    if (!previewData) return;
    const name = `${employee.first_name} ${employee.last_name}`.trim();
    try {
      setLoading(true);
      setError(null);
      setNotice(null);
      // The server records why for a plain rematch; the portal path needs it said.
      await matchAgain(previewData, `Matched again after ${name} was reactivated`, employee.id,
        `${name} is active again and is now matched in this import.`, `${name} is active again. Their row still needs attention below.`, false);
    } catch (err) {
      setError(`${name} is active again, but the files could not be matched again. ${err instanceof Error ? err.message : ''} Upload the files again to match them.`.trim());
    } finally {
      setLoading(false);
    }
  };

  // Set up (or resume) the Employee Loan the workbook's installment needs, then
  // match the files again so the review reconciles it. Errors reach the form.
  const handleInstallmentLoan = async (row: ImportPreviewRow, fields?: InstallmentLoanSubmission) => {
    if (!previewData) return;
    const current = previewData;
    const resume = row.installment_loan_setup?.action === 'resume';
    const what = resume ? `${row.installment_loan_setup?.name} for ${row.employee_name}` : `${row.employee_name}’s installment loan`;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const sourceType = current.source_package.source_type;
      const result = await payPeriodsApi.setUpImportInstallmentLoan(payPeriodId, {
        import_id: current.import_id,
        employee_id: row.employee_id,
        ...(sourceType ? { source_type: sourceType } : {}),
        ...fields,
      });
      const done = resume ? `${what} is resumed` : result.already_set_up ? `${what} was already set up` : `${what} is set up`;
      try {
        await matchAgain(current, resume ? `Matched again after ${what} was resumed` : `Matched again after ${what} was set up`, row.employee_id,
          `${done} and matches this import.`, `${done}. Their row still needs attention below.`);
      } catch (err) {
        setError(`${done}, but the files could not be matched again. ${err instanceof Error ? err.message : ''} Try again; no second loan is created.`.trim());
      }
    } finally {
      setLoading(false);
    }
  };

  // Add the missing file from the review. The package keeps the file already
  // received, matching runs again, and outcomes chosen so far are kept.
  const addSourceFile = async (role: string, file: File) => {
    if (!previewData || loading) return;
    if (!SUPPORTED_REVIEWED_IMPORT_ROLES.has(role)) {
      setError(`This reviewed-hours import endpoint does not support the "${role}" file role.`);
      return;
    }
    const previousRows = sourceRows;
    const pendingSubmissionId = usePendingRevision ? previewData.pending_portal_source?.submission_id : undefined;
    try {
      setLoading(true);
      setAddingSource(true);
      setError(null);
      const data = await payPeriodsApi.previewImport(
        payPeriodId,
        role === 'revel_hours' ? file : undefined,
        role === 'supplemental_workbook' ? file : undefined,
        // No tip fallback is offered here: a workbook added from the review gets
        // its own choice, and one already saved for the same workbook is kept.
        undefined,
        undefined,
        undefined,
        activeSourceType,
      );
      openPreview(data, previousRows, pendingSubmissionId);
      onSourcePreviewed?.();
      void refreshCurrentPackage();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not add the file');
    } finally {
      setLoading(false);
      setAddingSource(false);
    }
  };

  // Take a file out of the open import, for example a workbook added by
  // mistake. The other files are kept and outcomes chosen so far are kept.
  const removeSourceFile = async (role: string, reason: string) => {
    if (!previewData || loading) return false;
    const previousRows = sourceRows;
    const pendingSubmissionId = usePendingRevision ? previewData.pending_portal_source?.submission_id : undefined;
    try {
      setLoading(true);
      setError(null);
      const sourceType = previewData.source_package.source_type;
      const data = sourceType
        ? await payPeriodsApi.removeImportSource(payPeriodId, role, reason, sourceType)
        : await payPeriodsApi.removeImportSource(payPeriodId, role, reason);
      openPreview(data, previousRows, pendingSubmissionId);
      if (role === 'supplemental_workbook') setNoTipsOrLoans(false);
      onSourcePreviewed?.();
      void refreshCurrentPackage();
      return true;
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not remove the file');
      return false;
    } finally {
      setLoading(false);
    }
  };

  // The choice is saved on the review so apply uses exactly what was shown.
  const saveTipTreatment = async (paid: boolean) => {
    if (!previewData || savingTips) return;
    try {
      setSavingTips(true);
      setError(null);
      const sourceType = previewData.source_package.source_type;
      const data = sourceType
        ? await payPeriodsApi.saveImportTipTreatment(payPeriodId, previewData.import_id, paid, sourceType)
        : await payPeriodsApi.saveImportTipTreatment(payPeriodId, previewData.import_id, paid);
      setPreviewData(data);
      setTipsPaidOutFromTips(data.preview.tips_paid_out_from_tips);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save the tip choice');
    } finally {
      setSavingTips(false);
    }
  };

  const handleApply = async () => {
    if (!previewData || loading || !canApply) return;
    try {
      setStep('applying');
      setError(null);
      const response = await payPeriodsApi.applyImport(payPeriodId, {
        import_id: previewData.import_id,
        portal_source_id: previewData.portal_source?.selection_id,
        use_submission_id: usePendingRevision ? previewData.pending_portal_source?.submission_id : undefined,
        rows: sourceRows.map((row) => ({
          id: row.id,
          disposition: row.disposition,
          disposition_reason: row.disposition_reason,
          target_pay_period_id: row.target_pay_period_id,
        })),
        acknowledge_low_confidence_matches: reviewedSuggestedMatches,
        force_overwrite: reviewedOverwrite,
        confirm_hours_overwrite: confirmHoursOverwrite,
        no_tips_or_loans: staffWaived,
        wage_rate_choices: rateChoices,
        ...(clientChanges.length ? { confirm_client_changes: reviewedClientChanges,
          reviewed_changes: clientChanges.map(row => {
            const base = {
              change_index: row.change_index,
              ...(isNoPay(row) ? { decision: 'no_pay', reason: noPayReason(row) } : clientDeclines[row.change_index] ? { decision: 'decline', reason: clientDeclineReasons[row.change_index] || '' } : clientAdjustmentReasons[row.change_index]?.trim() ? { reason: clientAdjustmentReasons[row.change_index] } : {}),
              ...(clientPayChoices[row.change_index] ? { pay_choice: clientPayChoices[row.change_index], saved_period_pay: row.saved_period_pay, workbook_period_pay: row.workbook_period_pay } : {}),
            };
            if (row.kind === 'owner_pay') {
              return { ...base, amount: clientChangeDrafts[row.change_index] ?? row.amount ?? '' };
            }
            const state = extraHoursReviewState(row);
            if (isNoPay(row) || clientDeclines[row.change_index]) {
              return { ...base, hours: row.hours ?? '' };
            }
            const baselineFields = {
              ...(row.baseline_regular_hours !== undefined || row.saved_regular_hours !== undefined
                ? { baseline_regular_hours: row.baseline_regular_hours ?? row.saved_regular_hours }
                : {}),
              ...(row.baseline_overtime_hours !== undefined || row.saved_overtime_hours !== undefined
                ? { baseline_overtime_hours: row.baseline_overtime_hours ?? row.saved_overtime_hours }
                : {}),
            };
            if (state.mode === 'split') {
              const regText = state.regularDraft.trim() || '0';
              const otText = state.overtimeDraft.trim() || '0';
              const totalHundredths = (parseDecimalHundredths(regText) ?? 0) + (parseDecimalHundredths(otText) ?? 0);
              return { ...base, ...baselineFields, regular_hours: regText, overtime_hours: otText, hours: formatCompactHours(totalHundredths) };
            }
            if (state.mode === 'workweek') {
              return { ...base, ...baselineFields, hours: state.hoursDraft, ...(state.workweekDraft ? { workweek: state.workweekDraft } : {}) };
            }
            return { ...base, ...baselineFields, hours: state.hoursDraft };
          }) } : {}),
      });
      setResults({
        success: response.results.success.length,
        errors: response.results.errors.map((e) => `${e.name}: ${e.error}`),
      });
      setStep('done');
      onImportComplete(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply import');
      setStep('preview');
    }
  };

  const updateSourceRow = (rowId: number, patch: Partial<EditableSourceRow>) => {
    setReviewedOverwrite(false);
    const source = sourceRows.find(row => row.id === rowId);
    const owner = clientChanges.find(change => change.requires_pay_decision && change.employee_id === source?.employee_id);
    if (owner) {
      setReviewedClientChanges(false);
      if (patch.disposition) setClientDeclines(current => ({ ...current, [owner.change_index]: false }));
    }
    setSourceRows((current) => current.map((row) => row.id === rowId ? { ...row, ...patch } : row));
  };

  const activeChangePrefill = previewData?.client_change_prefill || (usePendingRevision ? previewData?.pending_change_prefill : null);
  const clientChanges = activeChangePrefill?.rows || [];
  const isNoPay = (change: (typeof clientChanges)[number]) => !!change.requires_pay_decision && (!!clientDeclines[change.change_index] || sourceRows.some(row => row.employee_id === change.employee_id && row.disposition === 'excluded'));
  const noPayReason = (change: (typeof clientChanges)[number]) => sourceRows.find(row => row.employee_id === change.employee_id && row.disposition === 'excluded')?.disposition_reason || clientDeclineReasons[change.change_index] || '';
  const hasPayConflict = (row: (typeof clientChanges)[number]) => row.kind === 'owner_pay' && [row.saved_period_pay, row.workbook_period_pay].some(amount => amount !== undefined && Number(amount) !== Number(clientChangeDrafts[row.change_index] ?? row.amount));
  type ExtraHoursReviewEntry = {
    mode: ExtraHoursMode;
    hoursDraft: string;
    regularDraft: string;
    overtimeDraft: string;
    workweekDraft: number | undefined;
    preview: ReturnType<typeof computeExtraHoursPreview>;
    adjusted: boolean;
    missingSubmittedSplit: boolean;
    employeeActiveRowCount: number;
    employeeActiveRowIndex: number;
    cumulativeGrossPayDelta: number | null;
  };
  const extraHoursReviewMap = (() => {
    const map = new Map<number, ExtraHoursReviewEntry>();
    const activeCountByEmployee = new Map<number, number>();
    for (const row of clientChanges) {
      if (row.kind !== 'extra_hours' || !row.employee_id) continue;
      if (isNoPay(row) || clientDeclines[row.change_index] || row.error) continue;
      activeCountByEmployee.set(row.employee_id, (activeCountByEmployee.get(row.employee_id) ?? 0) + 1);
    }
    const runningByEmployee = new Map<number, {
      reg: number;
      ot: number;
      w1: number;
      w2: number;
      grossDeltaCents: number | null;
      seenCount: number;
      lineHours: Map<string, { reg: number; ot: number }>;
    }>();

    for (const row of clientChanges) {
      if (row.kind !== 'extra_hours') continue;
      const mode: ExtraHoursMode = row.extra_hours_mode || (row.is_contractor ? 'straight_time' : row.workweeks?.length ? 'workweek' : 'split');
      const hoursDraft = clientChangeDrafts[row.change_index] ?? row.hours ?? '';
      const regularDraft = clientExtraRegularDrafts[row.change_index] ?? row.regular_hours ?? '';
      const overtimeDraft = clientExtraOvertimeDrafts[row.change_index] ?? row.overtime_hours ?? '';
      const workweekDraft = row.workweeks?.length === 1 ? 1 : (clientExtraWorkweeks[row.change_index] ?? row.workweek ?? undefined);
      const selectedJobId = row.employee_id ? rateChoices[row.employee_id] : undefined;
      const isActive = !isNoPay(row) && !clientDeclines[row.change_index] && !row.error;
      const prior = isActive && row.employee_id ? runningByEmployee.get(row.employee_id) : undefined;
      const jobKey = `${row.employee_wage_rate_id ?? ''}:${row.wage_rate ?? ''}`;
      const priorLine = prior?.lineHours.get(jobKey);

      const initialLineRegular = selectedJobId !== undefined
        ? (selectedJobId === row.employee_wage_rate_id ? (row.baseline_line_regular_hours ?? row.baseline_regular_hours ?? row.saved_regular_hours ?? '0') : '0')
        : row.baseline_line_regular_hours;
      const initialLineOvertime = selectedJobId !== undefined
        ? (selectedJobId === row.employee_wage_rate_id ? (row.baseline_line_overtime_hours ?? row.baseline_overtime_hours ?? row.saved_overtime_hours ?? '0') : '0')
        : row.baseline_line_overtime_hours;

      const baseRegInput = prior ? prior.reg.toFixed(2) : (row.baseline_regular_hours ?? row.saved_regular_hours ?? '0');
      const baseOtInput = prior ? prior.ot.toFixed(2) : (row.baseline_overtime_hours ?? row.saved_overtime_hours ?? '0');
      const lineBaseRegInput = priorLine ? priorLine.reg.toFixed(2) : initialLineRegular;
      const lineBaseOtInput = priorLine ? priorLine.ot.toFixed(2) : initialLineOvertime;
      const baseW1Input = prior ? prior.w1.toFixed(2) : (row.baseline_week1_hours ?? '0');
      const baseW2Input = prior ? prior.w2.toFixed(2) : (row.baseline_week2_hours ?? '0');

      const preview = computeExtraHoursPreview({
        mode,
        rate: row.wage_rate,
        baselineRegularHours: baseRegInput,
        baselineOvertimeHours: baseOtInput,
        baselineLineRegularHours: lineBaseRegInput,
        baselineLineOvertimeHours: lineBaseOtInput,
        baselineWeek1Hours: baseW1Input,
        baselineWeek2Hours: baseW2Input,
        hours: hoursDraft,
        regularHours: regularDraft,
        overtimeHours: overtimeDraft,
        workweek: workweekDraft,
        workweekCount: row.workweeks?.length || 2,
      });

      const missingSubmittedSplit = row.needs_classification || (mode === 'split' && row.regular_hours === undefined && row.overtime_hours === undefined);
      let adjusted = false;
      if (mode === 'split') {
        if (missingSubmittedSplit) {
          const submittedTotal = parseDecimalHundredths(row.hours);
          adjusted = preview.valid && submittedTotal !== null && Math.round(preview.totalHours * 100) !== submittedTotal;
        } else {
          const regVal = parseDecimalHundredths(regularDraft.trim() || '0');
          const otVal = parseDecimalHundredths(overtimeDraft.trim() || '0');
          const origReg = parseDecimalHundredths(row.regular_hours ?? '0');
          const origOt = parseDecimalHundredths(row.overtime_hours ?? '0');
          adjusted = regVal !== origReg || otVal !== origOt;
        }
      } else if (mode === 'workweek') {
        const hoursChanged = parseDecimalHundredths(hoursDraft) !== parseDecimalHundredths(row.hours);
        const weekChanged = (row.workweeks?.length ?? 0) > 1 && row.workweek !== undefined && workweekDraft !== undefined && workweekDraft !== row.workweek;
        adjusted = hoursChanged || weekChanged;
      } else {
        adjusted = parseDecimalHundredths(hoursDraft) !== parseDecimalHundredths(row.hours);
      }

      const employeeActiveRowCount = isActive && row.employee_id ? (activeCountByEmployee.get(row.employee_id) ?? 1) : 1;
      const employeeActiveRowIndex = isActive ? (prior?.seenCount ?? 0) + 1 : 0;
      let cumulativeGrossPayDelta: number | null = preview.grossPayDelta;

      if (isActive && row.employee_id) {
        const prevCents = prior ? prior.grossDeltaCents : 0;
        const nextCents = prevCents !== null && preview.valid && preview.grossPayDelta !== null
          ? prevCents + Math.round(preview.grossPayDelta * 100)
          : null;
        cumulativeGrossPayDelta = nextCents === null ? null : nextCents / 100;

        const nextLineHours = new Map(prior?.lineHours ?? []);
        const prevLineReg = priorLine ? priorLine.reg : (Number(initialLineRegular ?? baseRegInput) || 0);
        const prevLineOt = priorLine ? priorLine.ot : (Number(initialLineOvertime ?? baseOtInput) || 0);
        if (preview.valid) {
          nextLineHours.set(jobKey, {
            reg: Math.round((prevLineReg + preview.deltaRegularHours) * 100) / 100,
            ot: Math.round((prevLineOt + preview.deltaOvertimeHours) * 100) / 100,
          });
        }
        runningByEmployee.set(row.employee_id, {
          reg: preview.valid ? preview.resultingRegularHours : (Number(baseRegInput) || 0),
          ot: preview.valid ? preview.resultingOvertimeHours : (Number(baseOtInput) || 0),
          w1: preview.valid && preview.resultingWeek1Hours !== undefined ? preview.resultingWeek1Hours : (Number(baseW1Input) || 0),
          w2: preview.valid && preview.resultingWeek2Hours !== undefined ? preview.resultingWeek2Hours : (Number(baseW2Input) || 0),
          grossDeltaCents: nextCents,
          seenCount: employeeActiveRowIndex,
          lineHours: nextLineHours,
        });
      }

      map.set(row.change_index, {
        mode,
        hoursDraft,
        regularDraft,
        overtimeDraft,
        workweekDraft,
        preview,
        adjusted,
        missingSubmittedSplit,
        employeeActiveRowCount,
        employeeActiveRowIndex,
        cumulativeGrossPayDelta,
      });
    }
    return map;
  })();
  const extraHoursReviewState = (row: (typeof clientChanges)[number]): ExtraHoursReviewEntry => extraHoursReviewMap.get(row.change_index)!;
  const changeRequiresAdjustmentReason = (row: (typeof clientChanges)[number]) => {
    if (isNoPay(row) || clientDeclines[row.change_index]) return false;
    if (row.kind === 'owner_pay') {
      const value = clientChangeDrafts[row.change_index] ?? row.amount ?? '';
      return (Number(value) !== Number(row.amount) && !row.requires_pay_decision) || Boolean(clientPayChoices[row.change_index] && clientPayChoices[row.change_index] !== 'client');
    }
    return extraHoursReviewState(row).adjusted;
  };
  const clientChangesInvalid = clientChanges.some(row => {
    if (isNoPay(row)) return !noPayReason(row).trim() || noPayReason(row).length > 1000;
    if (clientDeclines[row.change_index]) return !clientDeclineReasons[row.change_index]?.trim() || clientDeclineReasons[row.change_index].length > 1000;
    if (changeRequiresAdjustmentReason(row) && (!clientAdjustmentReasons[row.change_index]?.trim() || clientAdjustmentReasons[row.change_index].length > 1000)) return true;
    if (row.error) return true;
    if (row.kind === 'owner_pay') {
      const value = clientChangeDrafts[row.change_index] ?? row.amount ?? '';
      return !/^\d+(\.\d{1,2})?$/.test(value) || Number(value) <= 0 || Number(value) > 10_000_000 || (hasPayConflict(row) && !clientPayChoices[row.change_index]);
    }
    return !extraHoursReviewState(row).preview.valid;
  });
  const matched = (previewData?.preview.matched || []).map(row => {
    const owner = clientChanges.find(change => change.kind === 'owner_pay' && change.employee_id === row.employee_id && !change.error && !clientDeclines[change.change_index] && !isNoPay(change));
    if (!owner) return row;
    const choice = clientPayChoices[owner.change_index];
    const amount = choice === 'saved' ? owner.saved_period_pay : choice === 'workbook' ? owner.workbook_period_pay : clientChangeDrafts[owner.change_index] ?? owner.amount;
    return { ...row, period_pay_missing: false, period_pay_source: 'client_changes' as const, current_period_pay: amount };
  });
  const includedSourceRows = sourceRows.filter((row) => row.disposition === 'included');
  const includedSourceRowIds = new Set(includedSourceRows.map((row) => row.id));
  const included = matched.filter((row) => includedSourceRowIds.has(row.source_row_id));
  const clientOnlyEmployees = new Set(clientChanges.filter(change => change.employee_id && !change.error && !clientDeclines[change.change_index] && !isNoPay(change) && !matched.some(row => row.employee_id === change.employee_id)).map(change => change.employee_id));
  const reviewedEmployeeCount = included.length + clientOnlyEmployees.size;
  const missingPeriodPay = included.filter((row) => row.period_pay_missing);
  const missingRateChoices = included.filter((row) => row.wage_rate_options?.length && !(rateChoices[row.employee_id] ?? row.selected_wage_rate_id));
  // Equal-rate jobs with no single job in history default to the primary job. Pay is
  // the same, so this never blocks; staff can move the hours to a department job.
  const primaryJobDefaults = included.filter((row) => row.wage_rate_needs_review && rateChoices[row.employee_id] == null);
  const overwriteRows = [...included.filter((row) => row.overwrite_required),
    ...clientChanges.filter(change => change.overwrite_required && !clientDeclines[change.change_index] && !isNoPay(change) && !matched.some(row => row.employee_id === change.employee_id))];
  const incompleteSourceRows = sourceRows.filter((row) => (
    row.disposition === 'pending'
      || (['excluded', 'deferred', 'informational'].includes(row.disposition) && !row.disposition_reason?.trim())
      || (row.disposition === 'deferred' && !row.target_pay_period_id)
  ));
  const duplicateIncludedEmployeeIds = new Set(includedSourceRows.map((row) => row.employee_id).filter(Boolean).filter((id, index, ids) => ids.indexOf(id) !== index));
  const includedBlockingRows = includedSourceRows.filter((row) => row.errors.some((entry) => entry.code !== 'duplicate_employee' || duplicateIncludedEmployeeIds.has(row.employee_id)));
  const unresolvedCount = incompleteSourceRows.length + includedBlockingRows.length;
  const suggestedMatchCount = previewData?.preview.low_confidence_matches.filter((match) => includedSourceRows.some((row) => row.employee_id === match.employee_id)).length || 0;
  const suggestedMatches = previewData?.preview.low_confidence_matches.filter((match) => includedSourceRows.some((row) => row.employee_id === match.employee_id)) || [];
  const nonMatchedSourceRows = sourceRows.filter((row) => row.row_kind !== 'matched');
  const handEditedRows = included.filter((row) => row.hand_edited_hours);
  const packageSources = previewData?.source_package.sources || [];
  const clientWorkbookChoice = (previewData?.portal_source || (usePendingRevision ? previewData?.pending_portal_source : null))?.workbook_choice;
  const clientWaivedSources = clientWorkbookChoice === 'none';
  // The client sent the workbook or a link to it, so "No tips or loans" is not staff's to choose.
  const waiverBlockedReason = clientWorkbookChoice === 'link'
    ? 'The client sent a link to the workbook. Attach the workbook from the link above.'
    : clientWorkbookChoice === 'attach' ? 'The client attached a workbook. Open the client revision again so it is included.' : null;
  const staffWaived = noTipsOrLoans && !waiverBlockedReason;
  const missingSources = packageSources.filter((source) => source.required && !source.present
    && !(source.waiver_label && (staffWaived || clientWaivedSources)));
  // An older MoSa workbook has no per-person tip treatment, so staff choose it here,
  // including when the workbook was added after the first upload.
  const legacyWorkbook = Boolean(previewData?.preview.source_warnings?.some((warning) => warning.code === 'legacy_mosa_workbook'));
  const reviewTipsPaid = legacyWorkbook && !previewData?.preview.tip_treatment_confirmed ? null : Boolean(previewData?.preview.tips_paid_out_from_tips);
  const tipChoiceMissing = legacyWorkbook && reviewTipsPaid === null;
  const canRemoveSources = Boolean(previewData && !previewData.portal_source && previewData.source_package.current !== false
    && packageSources.filter((source) => source.present).length > 1);
  const canApply = Boolean(
    previewData
      && !loading
      && (!clientChanges.length || (reviewedClientChanges && !clientChangesInvalid))
      && sourceRows.length > 0
      && incompleteSourceRows.length === 0
      && includedBlockingRows.length === 0
      && duplicateIncludedEmployeeIds.size === 0
      && missingPeriodPay.length === 0
      && missingRateChoices.length === 0
      && (overwriteRows.length === 0 || reviewedOverwrite)
      && (handEditedRows.length === 0 || confirmHoursOverwrite)
      && missingSources.length === 0
      && !tipChoiceMissing
      && !savingTips
      && (suggestedMatchCount === 0 || reviewedSuggestedMatches),
  );
  // Upload step: which files the current package already has, and whether the
  // chosen files only add what is missing or replace something received.
  const currentRoles = new Set<string>((currentPackage?.documents || []).filter((document) => document.verification_status !== 'legacy_unverified').map((document) => document.source_role));
  const currentOpen = Boolean(currentPackage && ['previewed', 'reviewed'].includes(currentPackage.status));
  const chosenFiles = ([['revel_hours', pdfFile], ['supplemental_workbook', excelFile]] as const)
    .flatMap(([role, file]) => (file ? [{ role: role as string, file }] : []));
  const chosenRoles = chosenFiles.map((chosen) => chosen.role);
  const retainedDocument = (role: string) => (currentPackage?.documents || []).find((document) => document.source_role === role && document.verification_status !== 'legacy_unverified');
  const chosenDigest = (role: string, file: File) => (chosenDigests[role]?.file === file ? chosenDigests[role].sha256 : undefined);
  // Wait for the fingerprint only when the open import has a file in that slot to compare with.
  const checkingFiles = currentOpen && chosenFiles.some(({ role, file }) => retainedDocument(role)?.sha256 && chosenDigest(role, file) === undefined);
  // Chosen files the open import already holds byte for byte, such as after Back.
  const sameRoles = currentOpen ? chosenFiles.filter(({ role, file }) => {
    const sha256 = retainedDocument(role)?.sha256;
    return Boolean(sha256) && chosenDigest(role, file) === sha256;
  }).map(({ role }) => role) : [];
  const newRoles = chosenRoles.filter((role) => !sameRoles.includes(role));
  const reopensCurrent = currentOpen && chosenRoles.length > 0 && newRoles.length === 0;
  const replacing = Boolean(currentPackage) && newRoles.length > 0 && (!currentOpen || newRoles.some((role) => currentRoles.has(role)));
  const replacementReady = !replacing || replacementReason.trim().length > 0;

  // What still blocks Apply, in plain words, with a way to jump to each item. The long
  // review list can put the cause far from the Apply button on a phone.
  const unresolvedRows = [...incompleteSourceRows, ...includedBlockingRows.filter((row) => !incompleteSourceRows.includes(row))];
  const jumpToSection = (name: string) => {
    const section = reviewRef.current?.querySelector<HTMLElement>(`[data-attention="${name}"]`);
    section?.scrollIntoView?.({ block: 'center' });
    section?.focus();
  };
  const jumpToNextRow = () => {
    if (unresolvedRows.length === 0) return;
    const row = unresolvedRows[nextAttentionRow.current % unresolvedRows.length];
    nextAttentionRow.current += 1;
    const field = Array.from(reviewRef.current?.querySelectorAll<HTMLElement>('select[aria-label^="Outcome for "]') || [])
      .filter((candidate) => candidate.getAttribute('aria-label') === `Outcome for ${row.source_employee_name}`);
    const target = field.find((candidate) => candidate.offsetParent !== null) || field[0];
    target?.scrollIntoView?.({ block: 'center' });
    target?.focus();
  };
  const attention: { key: string; label: string; reason: string; jump: () => void }[] = [];
  if (missingSources.length > 0) {
    const labels = missingSources.map((source) => source.label).join(' and ');
    const waivable = !waiverBlockedReason && missingSources.every((source) => source.waiver_label);
    attention.push({ key: 'sources', label: waivable ? `Add the ${labels}, or confirm there are none` : `Add the ${labels}`, reason: `the ${labels} ${missingSources.length === 1 ? 'is' : 'are'} missing`, jump: () => jumpToSection('sources') });
  }
  if (tipChoiceMissing) {
    attention.push({ key: 'tips', label: 'Choose how the workbook’s tips were paid', reason: 'how the older workbook’s tips were paid is not chosen', jump: () => jumpToSection('tip-treatment') });
  }
  if (clientChanges.length && (!reviewedClientChanges || clientChangesInvalid)) {
    attention.push({ key: 'client-changes', label: 'Review the client’s amounts and hours', reason: 'client changes need confirmation', jump: () => jumpToSection('client-changes') });
  }
  if (missingPeriodPay.length > 0) {
    const names = missingPeriodPay.map((row) => row.employee_name).join(', ');
    attention.push({ key: 'pay', label: `Enter pay for ${names}`, reason: `pay is missing for ${names}`, jump: () => jumpToSection('missing-pay') });
  }
  if (missingRateChoices.length > 0) {
    const names = missingRateChoices.map((row) => row.employee_name).join(', ');
    attention.push({ key: 'rates', label: `Choose job and rate for ${names}`, reason: `no job and rate chosen for ${names}`, jump: () => jumpToSection('rate-choices') });
  }
  if (unresolvedRows.length > 0) {
    const count = unresolvedRows.length;
    attention.push({ key: 'rows', label: `Next row needing attention (${count})`, reason: `${count} source row${count === 1 ? ' needs' : 's need'} an outcome`, jump: jumpToNextRow });
  }
  if (suggestedMatchCount > 0 && !reviewedSuggestedMatches) {
    attention.push({ key: 'matches', label: `Confirm ${suggestedMatchCount} name match${suggestedMatchCount === 1 ? '' : 'es'}`, reason: 'suggested name matches are not confirmed', jump: () => jumpToSection('suggested-matches') });
  }
  if (overwriteRows.length > 0 && !reviewedOverwrite) {
    attention.push({ key: 'overwrite', label: 'Confirm replacing saved entries', reason: 'replacing saved entries is not confirmed', jump: () => jumpToSection('overwrite') });
  }
  if (handEditedRows.length > 0 && !confirmHoursOverwrite) {
    attention.push({ key: 'hand-edited', label: 'Confirm replacing hand-entered hours', reason: 'replacing hand-entered hours is not confirmed', jump: () => jumpToSection('hand-edited') });
  }
  // Notices that do not block Apply are grouped and collapsed to one line each.
  const sourceNotices = (previewData?.preview.source_warnings || []).filter((warning) => !(warning.code === 'missing_workbook' && packageSources.length > 0));
  // "Needs your action" holds only what keeps Apply off. The older-workbook notice
  // stays there until its tip choice is saved; serious notices that do not block
  // Apply are shown on their own, never counted as blockers.
  const actionNotices = sourceNotices.filter((warning) => warning.code === 'legacy_mosa_workbook' && tipChoiceMissing);
  const seriousNotices = sourceNotices.filter((warning) => warning.severity === 'error' && !actionNotices.includes(warning));
  const infoNotices = [
    ...sourceNotices.filter((warning) => warning.severity !== 'error' && !actionNotices.includes(warning)).map((warning) => ({ key: `source-${warning.code}`, title: noticeTitle(warning.code, warning.message), message: warning.message })),
    ...(primaryJobDefaults.length > 0 ? [{
      key: 'primary-job-defaults',
      title: `Hours on the primary job for ${primaryJobDefaults.length} worker${primaryJobDefaults.length === 1 ? '' : 's'}`,
      message: `The last committed payroll doesn’t show one job for ${primaryJobDefaults.map((row) => row.employee_name).join(', ')}, so their hours go on the primary job. Every job pays the same rate, so pay doesn’t change. If the hours belong to a department job, change Job and rate below; reports show hours by job.`,
    }] : []),
    ...(activeChangePrefill?.manual_review_warnings || []).map((message) => ({ key: `review-${message}`, title: noticeTitle(undefined, message), message })),
    ...(activeChangePrefill?.removals || []).map((message) => ({ key: `removal-${message}`, title: noticeTitle(undefined, message), message })),
  ];
  const applyBlockedReason = canApply ? null : attention.length > 0 ? `Apply is off: ${attention.map((item) => item.reason).join('; ')}.` : 'Apply is off until the items marked in this review are finished.';

  const rateChoiceControl = (row: ImportPreviewRow): ReactElement | null => row.wage_rate_options?.length ? (
    <div className="mt-2 min-w-0 max-w-xs space-y-1 whitespace-normal text-left">
      <label className="block text-xs font-medium text-neutral-700">
        Job and rate
        <select
          aria-label={`Job and rate for ${row.employee_name}`}
          className="mt-1 block min-h-11 w-full min-w-0 max-w-full rounded-lg border border-neutral-300 bg-white px-2 py-2 text-base"
          value={rateChoices[row.employee_id] ?? row.selected_wage_rate_id ?? ''}
          onChange={(event) => { setRateChoices((current) => ({ ...current, [row.employee_id]: Number(event.target.value) })); setReviewedClientChanges(false); }}
        >
          <option value="">Choose a job and rate</option>
          {row.wage_rate_options.map((option) => <option key={option.id} value={option.id}>{option.label} · {formatCurrency(option.rate)}/hr</option>)}
        </select>
      </label>
      <p className="text-xs font-semibold text-neutral-800">
        {row.wage_rate_options.filter((option) => option.id === (rateChoices[row.employee_id] ?? row.selected_wage_rate_id)).map((option) => `${option.label} · ${formatCurrency(option.rate)}/hr`).join('')}
      </p>
      <p className={cn('text-xs', row.wage_rate_needs_review && rateChoices[row.employee_id] == null ? 'font-medium text-amber-800' : 'text-neutral-600')}>{row.wage_rate_default_source}</p>
      {rateChoices[row.employee_id] != null && rateChoices[row.employee_id] !== row.selected_wage_rate_id && <p className="text-xs text-neutral-600">Your selection will be used for all imported hours.</p>}
    </div>
  ) : null;

  // A matched row's own problems, such as a loan that doesn't reconcile, with
  // the inline loan setup when the workbook's installment can be set up here.
  const rowIssues = (row: ImportPreviewRow, sourceRow: EditableSourceRow): ReactElement | null => {
    const offer = row.installment_loan_setup;
    const errors = sourceRow.errors.filter((entry) => entry.message !== offer?.message);
    if (!offer && errors.length === 0) return null;
    return (
      <div className="mt-2 min-w-0 max-w-md space-y-2 whitespace-normal">
        {errors.map((entry, index) => <p key={`${entry.code}-${index}`} className="text-sm text-danger-700">{entry.message}</p>)}
        {offer && previewData && (
          <InstallmentLoanSetup
            key={`${previewData.import_id}-${row.employee_id}`}
            employeeName={row.employee_name}
            offer={offer}
            access={previewData.loan_setup}
            disabled={loading}
            onCreate={(fields) => handleInstallmentLoan(row, fields)}
            onResume={() => handleInstallmentLoan(row)}
          />
        )}
      </div>
    );
  };

  const missingHoursNotice = (row: ImportPreviewRow): ReactElement | null => row.missing_revel_hours_with_deductions ? (
    <p className="mt-2 max-w-xs whitespace-normal text-xs font-medium text-amber-800">No Revel hours — enter hours from MoSa's email before calculating. Any hours already entered will be kept.</p>
  ) : null;

  const dispositionControls = (row: EditableSourceRow) => (
    <div className="space-y-2">
      <Select
        aria-label={`Outcome for ${row.source_employee_name}`}
        value={row.disposition}
        // Matching again restores outcomes from when it started; a change made meanwhile would be lost.
        disabled={loading}
        onChange={(event) => {
          const disposition = event.target.value as EditableSourceRow['disposition'];
          updateSourceRow(row.id, {
            disposition,
            disposition_reason: disposition === 'included' ? null : row.disposition_reason,
            target_pay_period_id: disposition === 'deferred' ? row.target_pay_period_id : null,
          });
        }}
      >
        <option value="pending">Choose outcome</option>
        {row.row_kind === 'matched' && <option value="included">Include in this payroll</option>}
        <option value="excluded">Exclude from payroll</option>
        <option value="deferred">Move to a future payroll</option>
        <option value="informational">Informational only</option>
      </Select>
      {['excluded', 'deferred', 'informational'].includes(row.disposition) && (
        <>
          <Input
            aria-label={`Reason for ${row.source_employee_name}`}
            value={row.disposition_reason || ''}
            disabled={loading}
            onChange={(event) => updateSourceRow(row.id, { disposition_reason: event.target.value })}
            placeholder="Required reason"
          />
          {row.disposition === 'deferred' && (
            <Select
              aria-label={`Future payroll for ${row.source_employee_name}`}
              value={row.target_pay_period_id ? String(row.target_pay_period_id) : ''}
              disabled={loading}
              onChange={(event) => updateSourceRow(row.id, { target_pay_period_id: event.target.value ? Number(event.target.value) : null })}
            >
              <option value="">Choose future payroll</option>
              {previewData?.source_package.disposition_targets.map((target) => <option key={target.id} value={target.id}>{target.label}</option>)}
            </Select>
          )}
        </>
      )}
    </div>
  );

  // Review uses the full width with the retained source files beside it.
  const sourceFiles = importSourceFiles(previewData?.source_package.documents);
  const showSources = (step === 'preview' || step === 'applying') && Boolean(previewData) && Boolean(sourceFiles.pdf || sourceFiles.workbook);

  return (
    <Dialog open={open} onOpenChange={handleClose} dismissOnEscape={!loading && step !== 'applying'}>
      <DialogContent className={cn('dialog-top max-h-[calc(100vh-8rem)] overflow-y-auto', showSources ? 'dialog-full' : 'dialog-wide max-w-6xl')}>
        <DialogHeader>
          <DialogTitle>Import Payroll Data</DialogTitle>
          <DialogDescription>
            {step === 'upload' && 'Upload the Revel hours PDF and the tips & loans workbook, together or one at a time.'}
            {(step === 'preview' || step === 'applying') && (unresolvedCount > 0
              ? `${unresolvedCount} source row${unresolvedCount === 1 ? ' needs' : 's need'} attention before this import can be applied.`
              : missingPeriodPay.length > 0
                ? 'Enter the missing period pay before applying this import.'
                : `${reviewedEmployeeCount} employees are ready. Review the source matches and apply.`)}
            {step === 'done' && 'Import complete.'}
          </DialogDescription>
        </DialogHeader>

        {error && (
          <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />
        )}

        {step === 'upload' && duplicateRevision && <div className="space-y-2 rounded-lg border border-warning-200 p-4">
          <p>These files were already applied. Review them with the changes from the pending client revision.</p>
          <Button disabled={loading} onClick={() => void handlePreview(duplicateRevision.id)}>Use this import for the client’s revision {duplicateRevision.revision}</Button>
        </div>}

        <div inert={step === 'applying'} className={showSources ? 'flex flex-col gap-4 xl:flex-row xl:items-start' : 'contents'}>
        {showSources && previewData && (
          <ImportSourcePanel key={previewData.source_package.id} className="xl:order-2" payPeriodId={payPeriodId}
            importId={previewData.source_package.id} documents={previewData.source_package.documents} />
        )}
        <div className={showSources ? 'min-w-0 flex-1 xl:order-1' : 'contents'}>
        {previewData?.pending_portal_source && !previewData.portal_source && <section className="space-y-2 rounded-lg border border-warning-200 bg-warning-50 p-4" aria-label="Pending client revision">
          <p className="text-sm">A client revision is waiting. Confirm that this import uses the files and changes for that revision. The selection is recorded only when this import applies successfully.</p>
          <h3 className="font-semibold">Client revision {previewData.pending_portal_source.revision} · changes for this period</h3>
          <Link className="inline-flex min-h-11 items-center text-sm underline" to={`/companies/${companyId}/payroll-submissions/${previewData.pending_portal_source.period_id}`}>Open retained portal submission</Link>
          <p className="text-sm">Select this revision to fill owner pay and extra hours for review. Review other changes separately before finalizing payroll.</p>
          <p className="text-sm">Workbook choice: {previewData.pending_portal_source.workbook_choice === 'attach' ? 'Attached workbook' : previewData.pending_portal_source.workbook_choice === 'link' ? 'Link sent' : previewData.pending_portal_source.workbook_choice === 'none' ? 'No tips or loans this period' : 'Not recorded'}</p>
          {previewData.pending_portal_source.no_changes && <p className="text-sm">No changes this period.</p>}
          <ul className="list-disc space-y-1 pl-5 text-sm">{previewData.pending_portal_source.changes.map((row, index) => <li className="break-words [overflow-wrap:anywhere]" key={index}>{row.label}: {changeSummary(row)}{row.note ? ` — ${row.note}` : ''}</li>)}</ul>
          {previewData.pending_portal_source.notes && <p className="whitespace-pre-wrap break-words text-sm">{previewData.pending_portal_source.notes}</p>}
          {previewData.pending_portal_source.changes_link_url && <a className="break-all text-sm underline" href={previewData.pending_portal_source.changes_link_url} target="_blank" rel="noopener noreferrer">Client’s tips &amp; loans workbook link</a>}
          <label className="flex min-h-11 items-center gap-2 text-sm font-semibold"><input type="checkbox" disabled={loading} checked={usePendingRevision} onChange={e => { setUsePendingRevision(e.target.checked); setReviewedClientChanges(false); setClientChangeDrafts({}); setClientExtraRegularDrafts({}); setClientExtraOvertimeDrafts({}); setClientExtraWorkweeks({}); setClientAdjustmentReasons({}); setClientDeclines({}); setClientDeclineReasons({}); setClientPayChoices({}); setReviewedOverwrite(false); }} />Use this import for the client’s revision {previewData.pending_portal_source.revision}</label>
        </section>}
        {previewData?.portal_source && <section aria-label="Portal change checklist" className="min-w-0 space-y-2 rounded-lg border border-primary-200 bg-primary-50 p-4">
          <h3 className="font-semibold">Client revision {previewData.portal_source.revision} · changes for this period</h3>
          <Link className="inline-flex min-h-11 items-center text-sm underline" to={`/companies/${companyId}/payroll-submissions/${previewData.portal_source.period_id}`}>Open retained portal submission</Link>
          <p className="text-sm">Submitted evidence stays unchanged. Owner pay and extra hours are filled below for confirmation; other changes still need staff review before finalizing payroll.</p>
          {!previewData.portal_source.current && <p className="text-sm font-semibold">You chose an older client revision, not the latest one. Reason: {previewData.portal_source.superseded_reason}</p>}
          {previewData.portal_source.no_changes && <p className="text-sm">No changes this period.</p>}
          <ul className="list-disc space-y-1 pl-5 text-sm">{previewData.portal_source.changes.map((row, index) => <li className="break-words" key={index}>{row.label}: {changeSummary(row)}{row.note ? ` — ${row.note}` : ''}</li>)}</ul>
          {previewData.portal_source.notes && <p className="whitespace-pre-wrap break-words text-sm">{previewData.portal_source.notes}</p>}
          {previewData.portal_source.changes_link_url && <a className="break-all text-sm underline" href={previewData.portal_source.changes_link_url} target="_blank" rel="noopener noreferrer">Client’s tips &amp; loans workbook link</a>}
          {previewData.portal_source.staff_workbook && <p className="break-all text-sm">Staff workbook: {previewData.portal_source.staff_workbook.filename} · attached by {previewData.portal_source.staff_workbook.attached_by_name} · {formatGuamDateTime(previewData.portal_source.staff_workbook.attached_at)} · SHA-256 {previewData.portal_source.staff_workbook.sha256}</p>}
          {previewData.portal_source.changes_link_url && previewData.preview.source_warnings?.some(w => w.code === 'missing_workbook') && <div className="space-y-2">
            <p className="text-sm">Open it, download the workbook, and attach it here.</p>
            <label className="block text-sm">Downloaded workbook (Excel)<input className="mt-2 block w-full" type="file" accept=".xls,.xlsx" onChange={e => setStaffWorkbook(e.target.files?.[0] || null)} /></label>
            <Button type="button" variant="outline" disabled={!staffWorkbook || loading} onClick={async () => {
              if (!staffWorkbook || !previewData.portal_source) return;
              setLoading(true); setError(null);
              try {
                const data = await payPeriodsApi.previewPortalSubmission(payPeriodId, previewData.portal_source.submission_id, {
                  staff_workbook: staffWorkbook, superseded_reason: previewData.portal_source.superseded_reason,
                  supersedes_package_id: previewData.source_package.package_id, supersession_reason: 'Staff attached the workbook from the client’s link',
                  tips_paid_out_from_tips: previewData.preview.tips_paid_out_from_tips,
                });
                openPreview(data); setStaffWorkbook(null); onSourcePreviewed?.();
              } catch (err) { setError(err instanceof Error ? err.message : 'Could not attach workbook'); }
              finally { setLoading(false); }
            }}>Attach workbook and refresh review</Button>
          </div>}
        </section>}

        {/* Upload Step */}
        {step === 'upload' && (
          <div className="space-y-4 py-2">
            {currentPackage && (
              <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
                <div className="flex items-start gap-3">
                  <RefreshCw className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />
                  <div className="min-w-0 flex-1">
                    <p className="font-semibold">{currentOpen ? `Import version ${currentPackage.package_revision} is the set of files currently in review` : `Import version ${currentPackage.package_revision} was already applied`}</p>
                    <p className="mt-1 text-sm text-amber-800">
                      {currentOpen
                        ? 'Continue the saved review, or add the file that is still missing below. Replacing a file already received needs a reason.'
                        : 'Upload again only when MoSa sends a correction.'}
                    </p>
                    {currentOpen && (
                      <Button type="button" variant="outline" size="sm" className="mt-3 border-amber-300 bg-white" onClick={() => void handleResumeCurrent()} disabled={loading}>
                        Continue import version {currentPackage.package_revision}
                      </Button>
                    )}
                  </div>
                </div>
              </div>
            )}
            <div className="rounded-2xl border border-primary-200 bg-primary-50/60 p-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="font-semibold text-primary-950">Start with this payroll's change-only workbook</p>
                  <p className="mt-1 text-sm text-primary-800">It is prefilled with Cornerstone employee IDs and the exact payroll dates. MoSa enters Mo and Sara’s pay separately, plus tips and approved period-only items. Recurring loans and 401(k) setup stay in Cornerstone.</p>
                </div>
                <Button type="button" variant="outline" onClick={handleDownloadTemplate} disabled={templateDownloading} className="shrink-0">
                  <Download className="mr-2 h-4 w-4" aria-hidden="true" />
                  {templateDownloading ? 'Preparing...' : 'Download workbook'}
                </Button>
              </div>
            </div>
            <fieldset className="space-y-3">
              <legend className="text-sm font-semibold text-neutral-950">Files for this payroll</legend>
              <p className="text-sm text-neutral-600">Add either file now and the other one later. The import is applied once both are in, or once you confirm there are no tips or loans.</p>
              <ul className="space-y-3">
                {sourcePickers.map((picker) => {
                  const chosen = picker.role === 'revel_hours'
                    ? pdfFile
                    : picker.role === 'supplemental_workbook'
                      ? excelFile
                      : null;
                  const kept = currentRoles.has(picker.role) ? currentPackage?.documents.find((document) => document.source_role === picker.role) : undefined;
                  return (
                    <li key={picker.role} className="rounded-xl border border-neutral-200 bg-white p-3">
                      <div className="flex min-w-0 items-start gap-2">
                        {chosen || kept
                          ? <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-green-700" aria-hidden="true" />
                          : <CircleDashed className="mt-0.5 h-5 w-5 shrink-0 text-neutral-400" aria-hidden="true" />}
                        <div className="min-w-0 flex-1">
                          <label htmlFor={`import-source-${picker.role}`} className="block font-medium text-neutral-950">{picker.label}</label>
                          <p className="mt-0.5 break-all text-xs text-neutral-700">
                            {chosen
                              ? `Selected: ${chosen.name}${sameRoles.includes(picker.role) ? ` · already in import version ${currentPackage?.package_revision}` : ''}`
                              : kept ? `In import version ${currentPackage?.package_revision}: ${kept.filename}` : 'Not added yet'}
                          </p>
                          <input
                            id={`import-source-${picker.role}`}
                            ref={picker.role === 'revel_hours' ? pdfInputRef : picker.role === 'supplemental_workbook' ? excelInputRef : undefined}
                            type="file"
                            accept={picker.accept || acceptByRole[picker.role]}
                            onChange={(event) => {
                              const file = event.target.files?.[0] || null;
                              if (picker.role === 'revel_hours') {
                                setPdfFile(file);
                              } else if (picker.role === 'supplemental_workbook') {
                                setExcelFile(file);
                                setTipsPaidOutFromTips(defaultTipsPaidOut);
                              } else if (file) {
                                setError(`This reviewed-hours import endpoint does not support the "${picker.role}" file role.`);
                              }
                            }}
                            className="mt-2 block w-full text-sm text-neutral-600 file:mr-3 file:min-h-11 file:rounded-md file:border-0 file:bg-primary-50 file:px-4 file:text-sm file:font-medium file:text-primary-700 hover:file:bg-primary-100"
                          />
                          <p className="mt-1 text-xs text-neutral-600">{picker.hint}</p>
                        </div>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </fieldset>

            {replacing && currentPackage && (
              <div className="rounded-xl border border-amber-300 bg-amber-50 p-3 text-amber-950">
                <p className="text-sm font-semibold">
                  {currentOpen
                    ? `This replaces the ${sourcePickers.filter((picker) => newRoles.includes(picker.role) && currentRoles.has(picker.role)).map((picker) => picker.label).join(' and ')} in import version ${currentPackage.package_revision}.`
                    : `Import version ${currentPackage.package_revision} was already applied. These files make a corrected version.`}
                </p>
                <Input
                  label="What changed?"
                  value={replacementReason}
                  onChange={(event) => setReplacementReason(event.target.value)}
                  placeholder="Example: MoSa corrected Mo’s regular hours."
                  className="mt-2 bg-white"
                />
              </div>
            )}

            <label className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900">
              <input
                type="checkbox"
                checked={tipsPaidOutFromTips}
                onChange={(event) => setTipsPaidOutFromTips(event.target.checked)}
                className="mt-0.5 rounded border-amber-300"
                disabled={!excelFile}
              />
              <span>
                <span className="font-medium">Legacy workbook fallback: all tips in this workbook were already paid out daily.</span>{' '}
                The generated workbook records this per employee, so this switch is only needed for an older MoSa workbook.
              </span>
            </label>
          </div>
        )}

        {/* Preview Step */}
        {step === 'upload' && (
          <p className="text-sm text-neutral-500">Older workbook only: an optional BONUSES sheet uses row 4 headers, column C last name, D first name, and F bonus amount. The current workbook uses dedicated OWNER PERIOD PAY and ONE-TIME COMPONENTS sheets.</p>
        )}

        {(step === 'preview' || step === 'applying') && previewData && (
          <div ref={reviewRef} className="space-y-3">
            {missingRateChoices.length > 0 && <p role="alert" data-attention="rate-choices" tabIndex={-1} className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Choose a job and rate for {missingRateChoices.map((row) => row.employee_name).join(', ')} using the Job and rate selectors below before applying.</p>}
            {packageSources.length > 0 ? (
              <ImportSourceChecklist
                sources={packageSources}
                acceptByRole={acceptByRole}
                summary={`Import version ${previewData.source_package.package_revision} · reference ${previewData.source_package.package_id.slice(0, 8)} · ${previewData.source_package.verified_source_count} of ${previewData.source_package.source_count} file${previewData.source_package.source_count === 1 ? '' : 's'} retained and verified`}
                onAdd={previewData.portal_source ? undefined : (role, file) => void addSourceFile(role, file)}
                onRemove={canRemoveSources ? removeSourceFile : undefined}
                busy={addingSource}
                waived={staffWaived}
                onWaivedChange={setNoTipsOrLoans}
                clientWaived={clientWaivedSources}
                waiverBlockedReason={waiverBlockedReason}
              />
            ) : (
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-2xl border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-900">
                <span className="inline-flex items-center gap-2 font-semibold">
                  <CheckCircle2 className="h-4 w-4" aria-hidden="true" />
                  {previewData.source_package.verified_source_count} source{previewData.source_package.source_count === 1 ? '' : 's'} retained and verified
                </span>
                <span>Import version {previewData.source_package.package_revision} <span className="text-green-800">· reference {previewData.source_package.package_id.slice(0, 8)}</span></span>
              </div>
            )}
            {notice && <p role="status" className="rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm font-medium text-green-900">{notice}</p>}
            {seriousNotices.map((warning) => (
              <p key={warning.code} role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm font-medium text-danger-900">{warning.message}</p>
            ))}
            {attention.length > 0 && (
              <section aria-label="Needs your action" className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
                <h3 className="font-semibold">Needs your action ({attention.length})</h3>
                <p className="mt-0.5 text-amber-900">Apply stays off until these are done.</p>
                {actionNotices.length > 0 && (
                  <ul className="mt-2 space-y-1">
                    {actionNotices.map((warning) => <li key={warning.code}>{warning.message}</li>)}
                  </ul>
                )}
                {attention.length > 0 && (
                  <ul className="mt-2 flex flex-col gap-2 sm:flex-row sm:flex-wrap">
                    {attention.map((item) => <li key={item.key}><Button type="button" variant="outline" className="w-full sm:w-auto" onClick={item.jump}>{item.label}</Button></li>)}
                  </ul>
                )}
              </section>
            )}
            {infoNotices.length > 0 && (
              <section aria-label="For your information" className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-sm text-neutral-800">
                <h3 className="flex items-center gap-2 font-semibold text-neutral-950"><Info className="h-4 w-4 shrink-0" aria-hidden="true" />For your information ({infoNotices.length})</h3>
                <ul className="mt-1 divide-y divide-neutral-200">
                  {infoNotices.map((item) => (
                    <li key={item.key}>
                      {item.title === item.message ? <p className="py-2.5">{item.message}</p> : <details className="group">
                        <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 py-2 [&::-webkit-details-marker]:hidden">
                          <span className="min-w-0">{item.title}</span>
                          <ChevronDown className="h-4 w-4 shrink-0 text-neutral-500 transition-transform group-open:rotate-180 motion-reduce:transition-none" aria-hidden="true" />
                        </summary>
                        <p className="pb-3 text-neutral-700">{item.message}</p>
                      </details>}
                    </li>
                  ))}
                </ul>
              </section>
            )}
            {legacyWorkbook && (
              <fieldset data-attention="tip-treatment" tabIndex={-1} className={cn('rounded-lg border p-3 text-sm', tipChoiceMissing ? 'border-amber-300 bg-amber-50 text-amber-950' : 'border-neutral-200 bg-white text-neutral-900')}>
                <legend className="sr-only">Tips in this older MoSa workbook</legend>
                <p className="font-semibold">Were the tips in this older MoSa workbook already paid out daily?</p>
                <p className="mt-0.5 text-neutral-700">This workbook doesn’t say per person, so one choice covers everyone in it. Choose before applying.</p>
                <div className="mt-2 flex flex-col gap-1 sm:flex-row sm:gap-6">
                  <label className="flex min-h-11 items-center gap-2">
                    <input type="radio" name="review-tips-paid" className="h-4 w-4 shrink-0" checked={reviewTipsPaid === true} disabled={savingTips || loading} onChange={() => void saveTipTreatment(true)} />
                    Yes, already paid daily — offset them from the checks
                  </label>
                  <label className="flex min-h-11 items-center gap-2">
                    <input type="radio" name="review-tips-paid" className="h-4 w-4 shrink-0" checked={reviewTipsPaid === false} disabled={savingTips || loading} onChange={() => void saveTipTreatment(false)} />
                    No, not paid yet — pay them in the checks
                  </label>
                </div>
                {savingTips && <p role="status" className="mt-1 text-neutral-700">Saving…</p>}
              </fieldset>
            )}
            {ownerPayError && missingPeriodPay.length === 0 && (
              <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 pb-4 pt-1 text-sm">{ownerPayFeedback}</div>
            )}
            {clientChanges.length > 0 && <section data-attention="client-changes" tabIndex={-1} aria-label="From the client's changes" className="space-y-3 rounded-lg border border-info-200 bg-info-50 p-4">
              <h3 className="font-semibold">From the client’s changes · revision {activeChangePrefill?.revision}</h3>
              <p className="text-sm">Review each person’s figures. You can edit them here before applying. Other submitted changes still need staff review.</p>
              {clientChanges.map(change => {
                const extraState = change.kind === 'extra_hours' ? extraHoursReviewState(change) : null;
                const rowDisabled = loading || !!change.error || !!clientDeclines[change.change_index] || isNoPay(change);
                return <div key={change.change_index} className="space-y-2 rounded-lg border border-neutral-200 bg-white p-3">
                  {change.requires_pay_decision && <p className="text-sm font-medium text-warning-900">Earlier client pay is no longer selected. Enter new pay for this period, or choose No pay this period and record why. Exclude from payroll below has the same effect: no paycheck for this run.</p>}
                  <label className="flex min-h-11 items-center gap-2 text-sm font-medium"><input type="checkbox" disabled={loading} checked={isNoPay(change) || !!clientDeclines[change.change_index]} onChange={event => { setClientDeclines(current => ({ ...current, [change.change_index]: event.target.checked })); setReviewedClientChanges(false); setReviewedOverwrite(false); if (change.requires_pay_decision) setSourceRows(current => current.map(row => row.employee_id === change.employee_id ? { ...row, disposition: event.target.checked ? 'excluded' : 'included', disposition_reason: event.target.checked ? noPayReason(change) : '' } : row)); }} />{change.requires_pay_decision ? 'No pay this period for' : 'Don’t apply this change for'} {change.employee_name || 'missing employee'}</label>
                  {change.previous_value && <p className="text-sm text-neutral-600">Previous entry: {change.previous_value} → This revision: {change.amount || change.hours || 'None'}</p>}
                  {changeRequiresAdjustmentReason(change) && <Input label={`Reason for changing ${change.employee_name}'s entry`} disabled={loading} value={clientAdjustmentReasons[change.change_index] || ''} maxLength={1000} onChange={event => { setClientAdjustmentReasons(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }} />}
                  {(isNoPay(change) || clientDeclines[change.change_index]) && <Input label={`Reason for ${change.requires_pay_decision ? 'no pay for' : 'declining'} ${change.employee_name || 'this change'}`} disabled={loading} value={isNoPay(change) ? noPayReason(change) : clientDeclineReasons[change.change_index] || ''} maxLength={1000} onChange={event => { setClientDeclineReasons(current => ({ ...current, [change.change_index]: event.target.value })); if (change.requires_pay_decision) setSourceRows(current => current.map(row => row.employee_id === change.employee_id && row.disposition === 'excluded' ? { ...row, disposition_reason: event.target.value } : row)); setReviewedClientChanges(false); }} />}
                  {change.error && <p role={clientDeclines[change.change_index] ? undefined : 'alert'} className={clientDeclines[change.change_index] ? 'text-sm text-neutral-600' : 'text-sm text-danger-700'}>{clientDeclines[change.change_index] ? `Will not be applied: ${change.error}` : change.error}</p>}
                  {change.kind === 'owner_pay' && (
                    <Input label={`Pay for ${change.employee_name || 'owner'} this period`}
                      inputMode="decimal" value={clientChangeDrafts[change.change_index] ?? change.amount ?? ''}
                      disabled={rowDisabled} onChange={event => { setClientPayChoices(current => ({ ...current, [change.change_index]: '' })); setClientChangeDrafts(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }} />
                  )}
                  {change.kind === 'extra_hours' && extraState && (
                    <div className="space-y-2">
                      {change.fallback_reason && <p className="text-xs text-amber-800">{change.fallback_reason}</p>}
                      {extraState.mode === 'split' && (
                        <>
                          {extraState.missingSubmittedSplit && !clientDeclines[change.change_index] && (
                            <p className="text-xs font-medium text-warning-900">
                              Client submitted {change.hours} total hours without a regular/overtime split. Enter regular and/or overtime hours before approving.
                            </p>
                          )}
                          <div className="grid gap-2 sm:grid-cols-2">
                            <Input
                              label={`Regular hours for ${change.employee_name || 'employee'}`}
                              inputMode="decimal"
                              value={extraState.regularDraft}
                              disabled={rowDisabled}
                              onChange={event => { setClientExtraRegularDrafts(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }}
                            />
                            <Input
                              label={`Overtime hours for ${change.employee_name || 'employee'}`}
                              inputMode="decimal"
                              value={extraState.overtimeDraft}
                              disabled={rowDisabled}
                              onChange={event => { setClientExtraOvertimeDrafts(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }}
                            />
                          </div>
                        </>
                      )}
                      {extraState.mode === 'workweek' && (
                        <>
                          <Input
                            label={`Extra hours for ${change.employee_name || 'employee'}`}
                            inputMode="decimal"
                            value={extraState.hoursDraft}
                            disabled={rowDisabled}
                            onChange={event => { setClientChangeDrafts(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }}
                          />
                          {(change.workweeks?.length || 0) > 1 ? (
                            <fieldset disabled={rowDisabled} className="space-y-1">
                              <legend className="text-xs font-medium text-neutral-700">Workweek for {change.employee_name || 'employee'}</legend>
                              {!extraState.workweekDraft && !clientDeclines[change.change_index] && (
                                <p className="text-xs font-medium text-warning-900">Choose which workweek these hours belong to before approving.</p>
                              )}
                              <div className="flex flex-wrap gap-2">
                                {change.workweeks!.map(week => (
                                  <Button
                                    key={week.index}
                                    type="button"
                                    size="sm"
                                    variant={extraState.workweekDraft === week.index ? 'primary' : 'outline'}
                                    aria-pressed={extraState.workweekDraft === week.index}
                                    disabled={rowDisabled}
                                    onClick={() => { setClientExtraWorkweeks(current => ({ ...current, [change.change_index]: week.index })); setReviewedClientChanges(false); }}
                                  >
                                    Week {week.index} ({week.label})
                                  </Button>
                                ))}
                              </div>
                            </fieldset>
                          ) : change.workweeks?.length === 1 ? (
                            <p className="text-xs text-neutral-700">Workweek: Week 1 ({change.workweeks[0].label})</p>
                          ) : null}
                        </>
                      )}
                      {extraState.mode === 'straight_time' && (
                        <>
                          <Input
                            label={`Extra hours for ${change.employee_name || 'employee'}`}
                            inputMode="decimal"
                            value={extraState.hoursDraft}
                            disabled={rowDisabled}
                            onChange={event => { setClientChangeDrafts(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }}
                          />
                          <p className="text-xs text-neutral-600">1099 contractor · straight time only (no overtime).</p>
                        </>
                      )}
                      {!clientDeclines[change.change_index] && !change.error && (
                        extraState.preview.valid ? (
                          <div
                            role="region"
                            aria-label={`Resulting hours and gross pay difference for ${change.employee_name || 'employee'}`}
                            className="space-y-0.5 rounded-md border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs text-neutral-800"
                          >
                            <p>
                              <span className="font-semibold">
                                {extraState.employeeActiveRowCount > 1 ? `Resulting hours (after change ${extraState.employeeActiveRowIndex} of ${extraState.employeeActiveRowCount}):` : 'Resulting hours:'}
                              </span>{' '}
                              {extraState.preview.resultingRegularHours.toFixed(2)} regular · {extraState.preview.resultingOvertimeHours.toFixed(2)} overtime
                              {' '}({extraState.preview.deltaRegularHours > 0 ? `+${extraState.preview.deltaRegularHours.toFixed(2)} reg` : extraState.preview.deltaRegularHours < 0 ? `${extraState.preview.deltaRegularHours.toFixed(2)} reg` : '0.00 reg'}
                              {extraState.preview.deltaOvertimeHours !== 0 ? `, ${extraState.preview.deltaOvertimeHours > 0 ? '+' : ''}${extraState.preview.deltaOvertimeHours.toFixed(2)} OT` : ''})
                            </p>
                            {extraState.preview.grossPayDelta !== null && (
                              <p>
                                <span className="font-semibold">Gross pay difference:</span>{' '}
                                {extraState.preview.grossPayDelta >= 0 ? '+' : ''}{formatCurrency(extraState.preview.grossPayDelta)}
                                {extraState.mode === 'straight_time' ? ' (straight time)' : ''}
                                {extraState.employeeActiveRowCount > 1 && extraState.cumulativeGrossPayDelta !== null
                                  ? ` · Combined for ${change.employee_name || 'employee'}: ${extraState.cumulativeGrossPayDelta >= 0 ? '+' : ''}${formatCurrency(extraState.cumulativeGrossPayDelta)}`
                                  : ''}
                              </p>
                            )}
                          </div>
                        ) : extraState.preview.error ? (
                          <p className="text-xs text-warning-900">{extraState.preview.error}</p>
                        ) : null
                      )}
                    </div>
                  )}
                  {change.kind === 'extra_hours' && change.saved_regular_hours !== undefined && <p className="text-xs text-neutral-600">Baseline before client hours: {change.saved_regular_hours} regular hours · {change.saved_overtime_hours || '0'} overtime hours.</p>}
                  {change.kind === 'owner_pay' && (change.saved_period_pay !== undefined || change.workbook_period_pay !== undefined) && <div className="space-y-2 text-sm">
                    {change.saved_period_pay !== undefined && <p>Existing pay: {formatCurrency(change.saved_period_pay)}</p>}
                    {change.workbook_period_pay !== undefined && <p>Workbook pay: {formatCurrency(change.workbook_period_pay)}</p>}
                    {hasPayConflict(change) && <p className="font-medium text-warning-900">These amounts differ. Choose which pay to use.</p>}
                    {hasPayConflict(change) && <label className="block">Pay choice for {change.employee_name}<select className="mt-1 min-h-11 w-full rounded-md border border-neutral-300 bg-white p-2" value={clientPayChoices[change.change_index] || ''} disabled={!!clientDeclines[change.change_index]} onChange={event => { setClientPayChoices(current => ({ ...current, [change.change_index]: event.target.value })); setReviewedClientChanges(false); }}>
                      <option value="">Choose pay</option><option value="client">Use client pay</option>
                      {change.saved_period_pay !== undefined && <option value="saved">Keep existing pay</option>}
                      {change.workbook_period_pay !== undefined && <option value="workbook">Use workbook pay</option>}
                    </select></label>}
                  </div>}
                  <p className="text-xs text-neutral-600">{change.kind === 'owner_pay' ? 'This person only · from the client’s changes' : `${change.wage_rate_label || 'Missing job'} · $${change.wage_rate || '?'} /hr · ${extraState?.mode === 'workweek' ? 'recomputed with 40-hour workweek overtime' : extraState?.mode === 'straight_time' ? 'added as straight-time hours' : 'added to matching regular and overtime buckets'}`}</p>
                </div>;
              })}
              <label className="flex min-h-11 items-start gap-2 text-sm font-medium"><input type="checkbox" className="mt-1 shrink-0" disabled={clientChangesInvalid} checked={reviewedClientChanges} onChange={event => setReviewedClientChanges(event.target.checked)} /><span>I checked the owner pay and extra hours from the client’s changes, including any edits above.</span></label>
            </section>}
            {missingPeriodPay.length > 0 && (
              <section role="alert" aria-label="Pay needed" data-attention="missing-pay" tabIndex={-1} className="rounded-lg border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
                <p className="font-medium">Period pay is required for {missingPeriodPay.map((row) => row.employee_name).join(', ')}.</p>
                <p className="mt-2">Enter each person’s own amount here and save it. You stay in this review. A combined amount for several owners is not accepted. If someone should not be paid in this run, choose a different outcome for them and record why.</p>
                <ul className="mt-3 space-y-3">
                  {missingPeriodPay.map((row) => {
                    const busy = ownerPayBusy === row.employee_id;
                    return (
                      <li key={row.source_row_id} className="flex flex-col gap-2 sm:flex-row sm:items-end">
                        <label className="block min-w-0 text-xs font-medium text-neutral-700 sm:w-72">
                          Pay for {row.employee_name} this period ($, this person only)
                          <NumericInput
                            className="mt-1 min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3"
                            aria-label={`Pay for ${row.employee_name} this period`}
                            value={ownerPayDrafts[row.employee_id] ?? null}
                            onValueChange={(value) => setOwnerPayDrafts((current) => ({ ...current, [row.employee_id]: value }))}
                            placeholder="0.00"
                            min={0}
                            fixedDecimalsOnBlur={2}
                            disabled={ownerPayBusy !== null}
                          />
                        </label>
                        <Button type="button" variant="outline" disabled={ownerPayBusy !== null || !ownerPayDrafts[row.employee_id]} onClick={() => void saveOwnerPay(row)}>
                          {busy ? 'Saving…' : `Save pay for ${row.employee_name}`}
                        </Button>
                      </li>
                    );
                  })}
                </ul>
                {ownerPayFeedback}
              </section>
            )}
            {overwriteRows.length > 0 && (
              <label data-attention="overwrite" tabIndex={-1} className="flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 p-4 text-xs text-warning-900">
                <input type="checkbox" checked={reviewedOverwrite} onChange={(event) => setReviewedOverwrite(event.target.checked)} className="shrink-0 self-start" />
                <span>Replace existing hours, tips and direct loan deductions with the reviewed source values for {overwriteRows.map((row) => row.employee_name).join(', ')}. {clientChanges.some(change => change.kind === 'owner_pay') ? 'Confirmed owner-pay changes replace the named owners’ period pay. Other saved period pay and manually entered bonuses are retained.' : 'Saved period pay and manually entered bonuses are retained.'}</span>
              </label>
            )}
            {handEditedRows.length > 0 && (
              <section data-attention="hand-edited" tabIndex={-1} aria-label="Hours entered by hand" className="rounded-lg border border-warning-200 bg-warning-50 p-4 text-sm text-warning-950">
                <p className="font-semibold">Revel hours will replace hours entered by hand ({handEditedRows.length})</p>
                <ul className="mt-2 space-y-1">
                  {handEditedRows.map((row) => {
                    const hours = row.hand_edited_hours!;
                    const overtimeChanged = Number(hours.saved_overtime_hours) !== Number(hours.source_overtime_hours);
                    return (
                      <li key={row.source_row_id} className="break-words">
                        <span className="font-medium">{row.employee_name}:</span>{' '}
                        {Number(hours.saved_regular_hours)} → {Number(hours.source_regular_hours)} regular
                        {overtimeChanged && <> · {Number(hours.saved_overtime_hours)} → {Number(hours.source_overtime_hours)} overtime</>}
                      </li>
                    );
                  })}
                </ul>
                <label className="mt-3 flex min-h-11 items-start gap-2 font-medium">
                  <input type="checkbox" className="mt-1 shrink-0" checked={confirmHoursOverwrite} onChange={(event) => setConfirmHoursOverwrite(event.target.checked)} />
                  <span>Replace the hand-entered hours with the Revel hours above.</span>
                </label>
              </section>
            )}
            {unresolvedCount > 0 && (
              <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900">
                <p className="font-medium">Choose a documented outcome for every source row.</p>
                <p className="mt-1 text-red-800">Included rows must be valid and unique. Anything not paid now needs a reason and, when deferred, a named future payroll.</p>
              </div>
            )}

            {nonMatchedSourceRows.length > 0 && (
              <div className="space-y-3 rounded-2xl border border-neutral-200 bg-neutral-50 p-4">
                <div>
                  <p className="font-semibold text-neutral-950">Source rows not matched for payment</p>
                  <p className="mt-1 text-sm text-neutral-600">Correct the source and upload a replacement, or record why each row is excluded, deferred, or informational.</p>
                </div>
                {nonMatchedSourceRows.map((row) => (
                  <div key={row.id} className="grid gap-3 rounded-2xl border border-neutral-200 bg-white p-4 md:grid-cols-[minmax(0,1fr)_300px]">
                    <div>
                      <p className="font-medium text-neutral-950">{row.source_employee_name}</p>
                      <p className="mt-1 text-xs text-neutral-600">{row.row_kind === 'unmatched_revel' ? 'Revel hours' : 'Change workbook'}</p>
                      {row.errors.map((entry) => <div key={entry.code} className="mt-2 text-sm">
                        <p className="text-danger-700">{entry.message}</p>
                        {entry.employee_id && <div className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1">
                          {entry.employee_status && ((entry.employee_status === 'terminated' ? canRehireWorkers : canReactivateWorkers)
                            ? <Button type="button" onClick={() => void startReactivation(entry.employee_id!)} disabled={loading || openingWorker !== null}>
                                {openingWorker === entry.employee_id ? 'Opening…' : `Reactivate ${entry.employee_name}`}
                              </Button>
                            : <p className="text-neutral-700">{entry.employee_status === 'terminated'
                                ? `${entry.employee_name} was terminated. A manager or admin can rehire them.`
                                : `You don't have access to reactivate ${entry.employee_name}.`}</p>)}
                          <Link
                            to={`/companies/${companyId}/employees/${entry.employee_id}/edit`}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="inline-flex min-h-11 items-center font-medium text-primary-700 underline"
                            aria-label={`Open profile for ${row.source_employee_name} (opens in a new tab)`}
                          >Open profile</Link>
                        </div>}
                      </div>)}
                    </div>
                    {dispositionControls(row)}
                  </div>
                ))}
              </div>
            )}

            {suggestedMatchCount > 0 && (
              <div data-attention="suggested-matches" tabIndex={-1} className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                <p className="font-medium">Review {suggestedMatchCount} suggested name match{suggestedMatchCount === 1 ? '' : 'es'}</p>
                <ul className="mt-2 space-y-1">
                  {suggestedMatches.map((match, index) => (
                    <li key={`${match.source}-${match.source_name}-${match.employee_id}-${index}`}>
                      {match.source}: “{match.source_name}” → {match.employee_name} ({Math.round(match.confidence * 100)}%)
                    </li>
                  ))}
                </ul>
                <label className="mt-3 flex items-start gap-2 font-medium">
                  <input
                    type="checkbox"
                    checked={reviewedSuggestedMatches}
                    onChange={(event) => setReviewedSuggestedMatches(event.target.checked)}
                    className="mt-0.5 rounded border-amber-300"
                  />
                  <span>I reviewed these suggestions and they point to the correct employees.</span>
                </label>
              </div>
            )}

            <div className="space-y-3 sm:hidden" aria-label="Matched payroll source rows">
              {matched.map((row) => {
                const sourceRow = sourceRows.find((candidate) => candidate.id === row.source_row_id);
                if (!sourceRow) return null;
                const classifiedLoanAmount = (row.one_payroll_deduction || 0) + (row.recurring_loan_deduction || 0) + (row.installment_payment || 0);
                const sourceLoanAmount = Math.max(row.loan_deduction || 0, classifiedLoanAmount);
                return (
                  <section key={row.source_row_id} className="space-y-3 rounded-2xl border border-neutral-200 bg-white p-4" aria-label={`Source row for ${row.employee_name}`}>
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0"><p className="font-semibold text-neutral-950">{row.employee_name}</p>{row.payroll_setup_only && <p className="text-xs text-neutral-600">From payroll setup, absent from source files. Review this person’s period pay.</p>}{row.pdf_employee_name && row.pdf_employee_name !== row.employee_name && <p className="text-xs text-neutral-600">PDF: {row.pdf_employee_name}</p>}</div>
                      <Badge variant={row.confidence >= 1 ? 'default' : row.confidence >= 0.8 ? 'warning' : 'danger'}>{row.payroll_setup_only ? 'Payroll setup' : `${Math.round(row.confidence * 100)}% match`}</Badge>
                    </div>
                    <div>{dispositionControls(sourceRow)}</div>
                    {missingHoursNotice(row)}
                    {rowIssues(row, sourceRow)}
                    {rateChoiceControl(row)}
                    <dl className="grid grid-cols-2 gap-3 text-sm">
                      <div><dt className="text-xs text-neutral-600">Hours</dt><dd className="font-medium">{row.regular_hours}{row.overtime_hours > 0 ? ` + ${row.overtime_hours} OT` : ''}</dd></div>
                      {!row.wage_rate_options?.length && <div><dt className="text-xs text-neutral-600">{row.period_pay_required ? 'Pay this person' : 'Profile rate'}</dt><dd className="font-medium">{row.period_pay_required ? (row.period_pay_missing || row.current_period_pay == null ? 'Missing period pay' : formatCurrency(row.current_period_pay)) : formatCurrency(row.pay_rate)}</dd></div>}
                      <div><dt className="text-xs text-neutral-600">Tips</dt><dd>{row.total_tips > 0 ? formatCurrency(row.total_tips) : '—'}{row.tip_pool ? ` · ${row.tip_pool.toUpperCase()}` : ''}</dd></div>
                      <div><dt className="text-xs text-neutral-600">Loan deduction</dt><dd>{sourceLoanAmount > 0 ? formatCurrency(sourceLoanAmount) : '—'}</dd></div>
                    </dl>
                    {sourceLoanAmount > 0 && (row.loan_reconciliation_matches || []).length > 0 && <p className="text-xs font-medium text-green-700">Matched loan: {(row.loan_reconciliation_matches || []).map((match) => match.name).join(', ')}</p>}
                    {(row.payroll_components || []).length > 0 && <div className="border-t border-neutral-100 pt-3 text-xs"><p className="mb-2 font-semibold text-neutral-700">One-time items</p>{(row.payroll_components || []).map((component, index) => <div key={`${component.label}-${index}`} className="py-1"><p className="flex justify-between gap-2"><span>{component.label}</span><span className="font-semibold tabular-nums">{formatCurrency(component.amount)}</span></p><p className="text-neutral-500">{component.tax_treatment.replaceAll('_', ' ')} · {component.category.replaceAll('_', ' ')}</p></div>)}</div>}
                    {(row.effective_bonus || 0) > 0 && <p className="text-xs text-neutral-600">Legacy bonus {formatCurrency(row.effective_bonus || 0)}{row.bonus_keeps_manual ? ' · retained manual value' : ''}</p>}
                  </section>
                );
              })}
            </div>
            <div className="hidden overflow-x-auto sm:block">
              <Table className="min-w-[1240px]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="min-w-[180px]">Outcome</TableHead>
                    <TableHead>Employee</TableHead>
                    <TableHead className="text-right">Hours</TableHead>
                    <TableHead className="text-right">Payroll rate</TableHead>
                    <TableHead className="text-right">Tips</TableHead>
                    <TableHead className="text-right">Loan Ded.</TableHead>
                    <TableHead className="min-w-[190px]">One-time items</TableHead>
                    <TableHead className="text-center">Match</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {matched.map((row) => {
                    const sourceRow = sourceRows.find((candidate) => candidate.id === row.source_row_id);
                    if (!sourceRow) return null;
                    const excluded = sourceRow.disposition !== 'included';
                    const classifiedLoanAmount = (row.one_payroll_deduction || 0) + (row.recurring_loan_deduction || 0) + (row.installment_payment || 0);
                    const sourceLoanAmount = Math.max(row.loan_deduction || 0, classifiedLoanAmount);
                    const issues = rowIssues(row, sourceRow);
                    return (
                      <Fragment key={row.source_row_id}>
                      <TableRow className={cn(excluded ? 'bg-neutral-50/70' : '', issues && 'border-b-0')}>
                        <TableCell>
                          {dispositionControls(sourceRow)}
                        </TableCell>
                        <TableCell>
                          <div>
                            <p className="font-medium text-neutral-900">{row.employee_name}</p>
                            {row.payroll_setup_only && <p className="text-xs text-neutral-600">From payroll setup, absent from source files. Review this person’s period pay.</p>}
                            {missingHoursNotice(row)}
                            {row.pdf_employee_name && row.pdf_employee_name !== row.employee_name && (
                              <p className="text-xs text-neutral-600">PDF: {row.pdf_employee_name}</p>
                            )}
                          </div>
                        </TableCell>
                        <TableCell className="text-right">
                          {row.regular_hours}
                          {row.overtime_hours > 0 && (
                            <span className="text-orange-600 ml-1">+{row.overtime_hours} OT</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          {rateChoiceControl(row)}
                          {!row.wage_rate_options?.length && <>
                          <p>{row.period_pay_required ? (row.period_pay_missing || row.current_period_pay == null ? 'Missing period pay' : formatCurrency(row.current_period_pay)) : formatCurrency(row.pay_rate)}</p>
                          <p className="text-xs text-neutral-600">
                            {row.period_pay_required
                              ? (row.period_pay_source === 'client_changes' ? 'Pay this person · from the client’s changes' : row.period_pay_source === 'change_workbook' ? 'Pay this person · change workbook' : 'Pay this person · payroll worksheet')
                              : 'from employee profile'}
                          </p>
                          </>}
                        </TableCell>
                        <TableCell className="text-right">
                          {row.total_tips > 0 ? (
                            <span>
                              {formatCurrency(row.total_tips)}
                              {row.tip_pool && (
                                <Badge variant="default" className="ml-1 text-xs">
                                  {row.tip_pool.toUpperCase()}
                                </Badge>
                              )}
                            </span>
                          ) : (
                            <span className="text-neutral-600">—</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          {sourceLoanAmount > 0 ? (
                            <div>
                              <p>{formatCurrency(sourceLoanAmount)}</p>
                              {((row.recurring_loan_deduction || 0) > 0 || (row.installment_payment || 0) > 0) && (
                                <p className="mt-0.5 text-xs text-neutral-600">
                                  {(row.recurring_loan_deduction || 0) > 0 && `This payroll ${formatCurrency(row.recurring_loan_deduction || 0)}`}
                                  {(row.recurring_loan_deduction || 0) > 0 && (row.installment_payment || 0) > 0 && ' · '}
                                  {(row.installment_payment || 0) > 0 && `Installment ${formatCurrency(row.installment_payment || 0)}`}
                                </p>
                              )}
                              {(row.loan_reconciliation_matches || []).length > 0 && (
                                <p className="mt-0.5 text-xs font-medium text-green-700">
                                  Matched to {(row.loan_reconciliation_matches || []).map((match) => match.name).join(', ')}
                                </p>
                              )}
                            </div>
                          ) : (
                            <span className="text-neutral-600">—</span>
                          )}
                        </TableCell>
                        <TableCell>
                          {(row.payroll_components || []).length > 0 || (row.effective_bonus || 0) > 0 ? (
                            <div className="space-y-2">
                              {(row.payroll_components || []).map((component, index) => (
                                <div key={`${row.source_row_id}-${component.label}-${index}`} className="rounded-lg border border-neutral-200 bg-neutral-50 px-2 py-2 text-xs">
                                  <div className="flex items-center justify-between gap-2">
                                    <span className="font-medium text-neutral-900">{component.label}</span>
                                    <span className={component.kind === 'deduction' ? 'font-semibold text-rose-700' : 'font-semibold text-emerald-700'}>
                                      {formatCurrency(component.amount)}
                                    </span>
                                  </div>
                                  <p className="mt-2 text-xs text-neutral-600">{component.tax_treatment.replaceAll('_', ' ')} · {component.category.replaceAll('_', ' ')}</p>
                                </div>
                              ))}
                              {(row.effective_bonus || 0) > 0 && (
                                <div className="text-xs text-neutral-700">
                                  Legacy bonus {formatCurrency(row.effective_bonus || 0)}{row.bonus_keeps_manual ? ' · retained manual value' : ''}
                                </div>
                              )}
                            </div>
                          ) : (
                            <span className="text-neutral-600">—</span>
                          )}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge variant={row.confidence >= 1.0 ? 'default' : row.confidence >= 0.8 ? 'warning' : 'danger'}>
                            {row.payroll_setup_only ? 'Payroll setup' : `${Math.round(row.confidence * 100)}%`}
                          </Badge>
                        </TableCell>
                      </TableRow>
                      {issues && (
                        // Full width under the worker, kept in view while the wide table scrolls.
                        <TableRow className={excluded ? 'bg-neutral-50/70' : ''}>
                          <TableCell colSpan={8} className="pt-0">
                            <div className="sticky left-0 max-w-2xl">{issues}</div>
                          </TableCell>
                        </TableRow>
                      )}
                      </Fragment>
                    );
                  })}
                </TableBody>
              </Table>
            </div>

            <div className="space-y-3 text-sm text-neutral-500">
              <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-neutral-700">
                <span className="font-medium">Tip treatment reviewed with these files:</span>{' '}
                {reviewTipsPaid === null
                  ? 'Not chosen yet.'
                  : reviewTipsPaid
                    ? 'Tips were already paid daily and will offset employee checks.'
                    : 'Tips were not already paid daily and will remain in employee checks.'}
              </div>
              <p>
                {previewData.preview.pdf_count} PDF records, {previewData.preview.excel_count} Excel records, {reviewedEmployeeCount} to import
              </p>
              <p>
                Gross pay and taxes will be calculated from employee profiles, imported hours, separate per-person period pay, tips, and typed one-time components. A manually entered legacy bonus is retained during reimport.
              </p>
              <p>
                Named recurring deductions and installment payments must match a configured ledger before import. The ledger records them only when payroll is committed. A separately labeled one-payroll deduction applies only to this run.
              </p>
            </div>
          </div>
        )}

        </div>
        </div>

        {/* Done Step */}
        {step === 'done' && results && (
          <div className="space-y-3 py-2">
            <div className="p-3 bg-green-50 border border-green-200 text-green-800 rounded-lg text-sm">
              Successfully imported {results.success} employee{results.success !== 1 ? 's' : ''}.
            </div>
            {results.errors.length > 0 && (
              <div className="p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">
                <p className="font-medium">Errors:</p>
                <ul className="mt-1 list-disc list-inside">
                  {results.errors.map((err, i) => (
                    <li key={i}>{err}</li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        )}

        <div className={(step === 'preview' || step === 'applying') ? 'sticky -bottom-4 z-10 -mx-4 border-t border-neutral-200 bg-white px-4 pb-4 sm:-bottom-6 sm:-mx-6 sm:px-6 sm:pb-6' : undefined}>
          {step === 'preview' && applyBlockedReason && (
            <p id="apply-blocked-reason" role="status" className="pt-3 text-sm font-medium text-amber-900">{applyBlockedReason}</p>
          )}
          <BusyStatus className="pt-3" busy={step === 'applying'}>Importing payroll data and calculating taxes…</BusyStatus>
          <DialogFooter>
            {step === 'upload' && (
              <>
                <Button variant="outline" onClick={handleClose} disabled={loading}>Cancel</Button>
                <Button onClick={() => void handlePreview()} disabled={(!pdfFile && !excelFile) || loading || checkingFiles || !replacementReady}>
                  {loading ? 'Parsing...' : checkingFiles ? 'Checking files…' : currentOpen && newRoles.length > 0 && !replacing ? `Add to import version ${currentPackage?.package_revision}` : 'Preview Import'}
                </Button>
              </>
            )}
            {(step === 'preview' || step === 'applying') && (
              <>
                <Button variant="outline" disabled={loading || step === 'applying'} onClick={() => {
                  if (loading) return;
                  if (initialPreview) { handleClose(); return; }
                  // A worker still loading for this review must not open over the upload step.
                  reviewGeneration.current += 1;
                  setOpeningWorker(null);
                  setStep('upload');
                  setUsePendingRevision(false); setStaffWorkbook(null);
    setReviewedClientChanges(false); setClientChangeDrafts({}); setClientExtraRegularDrafts({}); setClientExtraOvertimeDrafts({}); setClientExtraWorkweeks({}); setClientAdjustmentReasons({}); setClientDeclines({}); setClientDeclineReasons({}); setClientPayChoices({});
                  setPreviewData(null);
                  setSourceRows([]);
                  setReviewedSuggestedMatches(false);
                  setReviewedOverwrite(false);
                }}>
                  Back
                </Button>
                <Button loading={step === 'applying'} loadingLabel="Applying import…" onClick={handleApply} disabled={!canApply || step === 'applying'} aria-describedby={applyBlockedReason ? 'apply-blocked-reason' : undefined}>
                  Apply Import ({reviewedEmployeeCount} employees)
                </Button>
              </>
            )}
            {step === 'done' && (
              <Button onClick={handleClose}>Close</Button>
            )}
          </DialogFooter>
        </div>
      </DialogContent>
      {reactivating && (
        <EmployeeStatusTransitionDialog
          employee={reactivating}
          mode="reactivate"
          open
          onOpenChange={(next) => { if (!next) setReactivating(null); }}
          onCompleted={(employee) => void handleReactivated(employee)}
          defaultEffectiveDate={previewData?.pay_period?.start_date}
        />
      )}
    </Dialog>
  );
}
