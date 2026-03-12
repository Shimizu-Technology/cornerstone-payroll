/**
 * CPR-71 / CPR-73: Payroll Correction Panel
 *
 * Displayed on committed, voided, and correction-run pay periods.
 *
 * Provides:
 *   - Void source period        (committed → voided)
 *   - Create correction run     (voided → new draft correction)
 *   - Void correction run       (committed correction run → voided)
 *   - Delete draft correction run (draft correction run → deleted; reopens source)
 *   - Correction history / audit trail display
 *
 * CPR-73 improvements:
 *   - Clarified action labels and in-flight states for all four operations
 *   - Runbook-aligned warning / confirmation copy for irreversible actions
 *   - Failure/recovery messaging with exact next-step guidance
 *   - Reason quality validation: min 10 chars + anti-placeholder guard
 *   - All action buttons and modal controls disabled during in-flight requests
 *   - Solid focus management + keyboard trap in every modal
 *   - Source↔correction linkage clarity in audit timeline
 */
import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { payPeriodsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type { PayPeriod, PayPeriodCorrectionEvent } from '@/types';

// ----------------------------------------------------------------
// Constants & config
// ----------------------------------------------------------------

const MIN_REASON_LENGTH = 10;

/** Guard against placeholder / low-quality reasons. */
const PLACEHOLDER_PATTERNS = [
  /^test$/i,
  /^n\/a$/i,
  /^na$/i,
  /^none$/i,
  /^reason$/i,
  /^fix$/i,
  /^error$/i,
  /^mistake$/i,
  /^wrong$/i,
  /^bad$/i,
];

function validateReason(value: string): string | null {
  const trimmed = value.trim();
  if (!trimmed) return 'A reason is required.';
  if (trimmed.length < MIN_REASON_LENGTH) {
    return `Reason must be at least ${MIN_REASON_LENGTH} characters. Be specific so the audit trail is useful.`;
  }
  if (PLACEHOLDER_PATTERNS.some((re) => re.test(trimmed))) {
    return 'Please provide a descriptive reason (e.g. "Employee hours were entered incorrectly for period").';
  }
  return null;
}

const ACTION_LABELS: Record<string, string> = {
  void_initiated:           'Period Voided',
  correction_run_created:   'Correction Run Created',
  correction_run_committed: 'Correction Run Committed',
  correction_run_deleted:   'Draft Correction Deleted',
};

const ACTION_BADGE_VARIANTS: Record<
  string,
  'default' | 'danger' | 'warning' | 'success' | 'info'
> = {
  void_initiated:           'danger',
  correction_run_created:   'warning',
  correction_run_committed: 'success',
  correction_run_deleted:   'info',
};

// Human-readable action descriptions shown on the audit timeline row
const ACTION_DESCRIPTIONS: Record<string, string> = {
  void_initiated:
    'YTD totals reversed. Source period is now voided and locked. A correction run can be created.',
  correction_run_created:
    'A new draft correction run was created from this voided period. Operator can adjust hours and commit.',
  correction_run_committed:
    'Correction run was committed. YTD totals updated. This correction is final.',
  correction_run_deleted:
    'Draft correction run was deleted before being committed. Source period is again open for a new correction run.',
};

// ----------------------------------------------------------------
// Component
// ----------------------------------------------------------------

interface CorrectionPanelProps {
  payPeriod: PayPeriod;
  onPayPeriodChange: (updated: PayPeriod) => void;
}

export function CorrectionPanel({
  payPeriod,
  onPayPeriodChange,
}: CorrectionPanelProps) {
  const navigate = useNavigate();

  // ---------- Void modal ----------
  const [showVoidModal, setShowVoidModal] = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const [voidConfirmText, setVoidConfirmText] = useState('');
  const [voidLoading, setVoidLoading] = useState(false);
  const [voidError, setVoidError] = useState<string | null>(null);

  // ---------- Correction run modal ----------
  const [showCorrectionModal, setShowCorrectionModal] = useState(false);
  const [correctionReason, setCorrectionReason] = useState('');
  const [correctionPayDate, setCorrectionPayDate] = useState(payPeriod.pay_date ?? '');
  const [correctionLoading, setCorrectionLoading] = useState(false);
  const [correctionError, setCorrectionError] = useState<string | null>(null);

  // ---------- Delete draft correction run modal ----------
  const [showDeleteDraftModal, setShowDeleteDraftModal] = useState(false);
  const [deleteDraftReason, setDeleteDraftReason] = useState('');
  const [deleteDraftLoading, setDeleteDraftLoading] = useState(false);
  const [deleteDraftError, setDeleteDraftError] = useState<string | null>(null);

  // ---------- History ----------
  const [historyEvents, setHistoryEvents] = useState<PayPeriodCorrectionEvent[] | null>(null);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);

  // Whether any modal action is in-flight (used to globally disable all action buttons)
  const anyActionInFlight = voidLoading || correctionLoading || deleteDraftLoading;

  useEffect(() => {
    setCorrectionPayDate(payPeriod.pay_date ?? '');
    setHistoryEvents(null);
    setHistoryOpen(false);
    setHistoryError(null);
  }, [
    payPeriod.id,
    payPeriod.pay_date,
    payPeriod.updated_at,
    payPeriod.correction_status,
    payPeriod.superseded_by_id,
    payPeriod.voided_at,
  ]);

  // ----------------------------------------------------------------
  // Void source period / void correction run
  // ----------------------------------------------------------------
  const handleVoidSubmit = async () => {
    const reasonErr = validateReason(voidReason);
    if (reasonErr) {
      setVoidError(reasonErr);
      return;
    }
    if (voidConfirmText !== 'VOID') {
      setVoidError("Type VOID (all caps) in the confirmation field to proceed.");
      return;
    }

    try {
      setVoidLoading(true);
      setVoidError(null);
      const response = await payPeriodsApi.void(payPeriod.id, {
        reason: voidReason.trim(),
      });
      onPayPeriodChange(response.pay_period);
      setShowVoidModal(false);
      setVoidReason('');
      setVoidConfirmText('');
      setHistoryEvents(null);
      setHistoryOpen(false);
      setHistoryError(null);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to void pay period.';
      setVoidError(buildErrorWithRecovery(msg));
    } finally {
      setVoidLoading(false);
    }
  };

  // ----------------------------------------------------------------
  // Create correction run
  // ----------------------------------------------------------------
  const handleCorrectionSubmit = async () => {
    const reasonErr = validateReason(correctionReason);
    if (reasonErr) {
      setCorrectionError(reasonErr);
      return;
    }

    setCorrectionLoading(true);
    setCorrectionError(null);

    try {
      const response = await payPeriodsApi.createCorrectionRun(payPeriod.id, {
        reason:   correctionReason.trim(),
        pay_date: correctionPayDate || undefined,
      });
      onPayPeriodChange(response.source_pay_period);
      setShowCorrectionModal(false);
      setCorrectionReason('');
      navigate(`/pay-periods/${response.correction_run.id}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to create correction run.';
      setCorrectionError(buildErrorWithRecovery(msg));
    } finally {
      setCorrectionLoading(false);
    }
  };

  // ----------------------------------------------------------------
  // Delete draft correction run
  // ----------------------------------------------------------------
  const handleDeleteDraftSubmit = async () => {
    const reasonErr = validateReason(deleteDraftReason);
    if (reasonErr) {
      setDeleteDraftError(reasonErr);
      return;
    }

    setDeleteDraftLoading(true);
    setDeleteDraftError(null);

    try {
      const response = await payPeriodsApi.deleteDraftCorrectionRun(payPeriod.id, {
        reason: deleteDraftReason.trim(),
      });
      // After deletion, close/reset local state and navigate to source period.
      setShowDeleteDraftModal(false);
      setDeleteDraftReason('');
      setHistoryEvents(null);
      setHistoryOpen(false);
      navigate(`/pay-periods/${response.source_pay_period.id}`);
    } catch (err) {
      const msg =
        err instanceof Error ? err.message : 'Failed to delete draft correction run.';
      setDeleteDraftError(buildErrorWithRecovery(msg));
    } finally {
      setDeleteDraftLoading(false);
    }
  };

  // ----------------------------------------------------------------
  // History
  // ----------------------------------------------------------------
  const loadHistory = async () => {
    try {
      setHistoryLoading(true);
      setHistoryError(null);
      const response = await payPeriodsApi.correctionHistory(payPeriod.id);
      setHistoryEvents(response.correction_events);
      setHistoryOpen(true);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to load correction history.';
      setHistoryError(
        `${msg} Refresh the page if the problem persists, or check your network connection.`
      );
    } finally {
      setHistoryLoading(false);
    }
  };

  const toggleHistory = () => {
    if (historyOpen) {
      setHistoryOpen(false);
    } else if (historyEvents !== null) {
      setHistoryOpen(true);
    } else {
      loadHistory();
    }
  };

  // ----------------------------------------------------------------
  // Render helpers
  // ----------------------------------------------------------------
  const isVoided    = payPeriod.correction_status === 'voided';
  const isCorrection = payPeriod.correction_status === 'correction';
  const isDraft     = payPeriod.status === 'draft';
  const canVoid     = payPeriod.can_void === true;
  const canCorrect  = payPeriod.can_create_correction_run === true;
  const canDeleteDraft = payPeriod.can_delete_draft_correction_run === true;

  const closeVoidModal = useCallback(() => {
    if (!voidLoading) setShowVoidModal(false);
  }, [voidLoading]);

  const closeCorrectionModal = useCallback(() => {
    if (!correctionLoading) setShowCorrectionModal(false);
  }, [correctionLoading]);

  const closeDeleteDraftModal = useCallback(() => {
    if (!deleteDraftLoading) setShowDeleteDraftModal(false);
  }, [deleteDraftLoading]);

  const voidReasonId      = useId();
  const voidConfirmId     = useId();
  const corrReasonId      = useId();
  const corrPayDateId     = useId();
  const deleteReasonId    = useId();

  return (
    <div className="space-y-4">

      {/* ---- Voided period status banner ---- */}
      {isVoided && (
        <div role="status" className="rounded-lg border border-red-200 bg-red-50 p-4">
          <div className="flex items-start gap-3">
            <span className="text-2xl" aria-hidden="true">⛔</span>
            <div className="flex-1">
              <p className="font-semibold text-red-800">
                This pay period has been voided — YTD totals reversed
              </p>
              {payPeriod.void_reason && (
                <p className="mt-1 text-sm text-red-700">
                  <strong>Void reason:</strong> {payPeriod.void_reason}
                </p>
              )}
              {payPeriod.voided_at && (
                <p className="mt-0.5 text-xs text-red-500">
                  Voided {new Date(payPeriod.voided_at).toLocaleString()}
                  {payPeriod.voided_by_name && ` by ${payPeriod.voided_by_name}`}
                </p>
              )}
              {payPeriod.superseded_by_id ? (
                <p className="mt-1 text-sm text-red-700">
                  A correction run has been created:{' '}
                  <button
                    className="font-medium underline text-red-800 hover:text-red-900 focus:outline-none focus:ring-2 focus:ring-red-400 rounded"
                    onClick={() =>
                      navigate(`/pay-periods/${payPeriod.superseded_by_id}`)
                    }
                  >
                    View correction run →
                  </button>
                </p>
              ) : (
                <p className="mt-1 text-sm text-red-700">
                  No correction run exists yet.{' '}
                  {canCorrect
                    ? 'Use "Create Correction Run" below to reprocess this payroll.'
                    : 'Contact your administrator if a correction run is needed.'}
                </p>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ---- Correction run linkage banner ---- */}
      {isCorrection && payPeriod.source_pay_period_id && (
        <div role="status" className="rounded-lg border border-amber-200 bg-amber-50 p-4">
          <div className="flex items-start gap-3">
            <span className="text-xl" aria-hidden="true">🔁</span>
            <div className="flex-1">
              <p className="text-sm font-medium text-amber-800">
                This is a <strong>correction run</strong> for{' '}
                <button
                  className="underline hover:text-amber-900 focus:outline-none focus:ring-2 focus:ring-amber-400 rounded"
                  onClick={() =>
                    navigate(`/pay-periods/${payPeriod.source_pay_period_id}`)
                  }
                >
                  source period #{payPeriod.source_pay_period_id}
                </button>
              </p>
              {isDraft && (
                <p className="mt-1 text-xs text-amber-700">
                  Status: <strong>Draft</strong> — adjust hours and calculate before committing.
                  You can delete this correction run while it is still a draft if it was created in error.
                </p>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ---- Action buttons ---- */}
      <div className="flex flex-wrap gap-2" role="group" aria-label="Correction actions">
        {canVoid && (
          <Button
            variant="outline"
            className="border-red-300 text-red-700 hover:bg-red-50 hover:border-red-400 focus:ring-red-400"
            disabled={anyActionInFlight}
            onClick={() => {
              setShowVoidModal(true);
              setVoidError(null);
              setVoidReason('');
              setVoidConfirmText('');
            }}
          >
            {isCorrection
              ? 'Void This Correction Run'
              : 'Void This Pay Period'}
          </Button>
        )}

        {canCorrect && (
          <Button
            variant="outline"
            className="border-amber-300 text-amber-700 hover:bg-amber-50 hover:border-amber-400 focus:ring-amber-400"
            disabled={anyActionInFlight}
            onClick={() => {
              setShowCorrectionModal(true);
              setCorrectionError(null);
              setCorrectionReason('');
              setCorrectionPayDate(payPeriod.pay_date ?? '');
            }}
          >
            Create Correction Run
          </Button>
        )}

        {canDeleteDraft && (
          <Button
            variant="outline"
            className="border-orange-300 text-orange-700 hover:bg-orange-50 hover:border-orange-400 focus:ring-orange-400"
            disabled={anyActionInFlight}
            onClick={() => {
              setShowDeleteDraftModal(true);
              setDeleteDraftError(null);
              setDeleteDraftReason('');
            }}
          >
            Delete Draft Correction Run
          </Button>
        )}

        <Button
          variant="outline"
          size="sm"
          onClick={toggleHistory}
          disabled={historyLoading || anyActionInFlight}
          aria-expanded={historyOpen}
        >
          {historyLoading
            ? 'Loading history…'
            : historyOpen
            ? 'Hide Correction History'
            : 'View Correction History'}
        </Button>
      </div>

      {historyError && (
        <p role="alert" className="text-sm text-red-600 rounded-md bg-red-50 border border-red-200 px-3 py-2">
          {historyError}
        </p>
      )}

      {/* ---- Correction History ---- */}
      {historyOpen && historyEvents !== null && (
        <div className="rounded-lg border border-gray-200 bg-gray-50">
          <div className="border-b px-4 py-3 flex items-center justify-between">
            <h4 className="font-semibold text-gray-800 text-sm">
              Correction History — Pay Period #{payPeriod.id}
            </h4>
            <span className="text-xs text-gray-400">
              {historyEvents.length} event{historyEvents.length !== 1 ? 's' : ''}
            </span>
          </div>
          {historyEvents.length === 0 ? (
            <p className="px-4 py-6 text-sm text-gray-500 text-center">
              No correction events recorded for this pay period.
            </p>
          ) : (
            <ol aria-label="Correction audit timeline" className="divide-y divide-gray-100">
              {(() => {
                const deletedRunIds = new Set<number>(
                  historyEvents
                    .filter((e) => e.action_type === 'correction_run_deleted')
                    .map((e) => {
                      const md = (e.metadata ?? {}) as Record<string, unknown>;
                      return typeof md.deleted_correction_run_id === 'number' ? md.deleted_correction_run_id : null;
                    })
                    .filter((id): id is number => id !== null)
                );

                return historyEvents.map((event, idx) => (
                  <CorrectionEventRow
                    key={event.id}
                    event={event}
                    index={idx + 1}
                    total={historyEvents.length}
                    deletedRunIds={deletedRunIds}
                  />
                ));
              })()}
            </ol>
          )}
        </div>
      )}

      {/* ================================================================
          VOID MODAL — Void Source Period / Void Correction Run
          ================================================================ */}
      {showVoidModal && (
        <CorrectionModal
          title={
            isCorrection
              ? 'Void Correction Run — Irreversible'
              : 'Void Pay Period — Irreversible'
          }
          dangerLevel="high"
          description={
            <VoidModalBody
              isCorrection={isCorrection}
              voidReasonId={voidReasonId}
              voidConfirmId={voidConfirmId}
              voidReason={voidReason}
              voidConfirmText={voidConfirmText}
              onReasonChange={setVoidReason}
              onConfirmTextChange={setVoidConfirmText}
              loading={voidLoading}
            />
          }
          errorMessage={voidError}
          confirmLabel={voidLoading ? 'Voiding…' : isCorrection ? 'Void Correction Run' : 'Void Pay Period'}
          confirmClassName="bg-red-600 hover:bg-red-700 focus:ring-red-500 text-white"
          loading={voidLoading}
          confirmDisabled={voidLoading || voidConfirmText !== 'VOID'}
          onConfirm={handleVoidSubmit}
          onCancel={closeVoidModal}
        />
      )}

      {/* ================================================================
          CREATE CORRECTION RUN MODAL
          ================================================================ */}
      {showCorrectionModal && (
        <CorrectionModal
          title="Create Correction Run"
          dangerLevel="medium"
          description={
            <CreateCorrectionModalBody
              corrReasonId={corrReasonId}
              corrPayDateId={corrPayDateId}
              correctionReason={correctionReason}
              correctionPayDate={correctionPayDate}
              onReasonChange={setCorrectionReason}
              onPayDateChange={setCorrectionPayDate}
              loading={correctionLoading}
            />
          }
          errorMessage={correctionError}
          confirmLabel={correctionLoading ? 'Creating…' : 'Create Correction Run'}
          confirmClassName="bg-amber-600 hover:bg-amber-700 focus:ring-amber-500 text-white"
          loading={correctionLoading}
          confirmDisabled={correctionLoading}
          onConfirm={handleCorrectionSubmit}
          onCancel={closeCorrectionModal}
        />
      )}

      {/* ================================================================
          DELETE DRAFT CORRECTION RUN MODAL
          ================================================================ */}
      {showDeleteDraftModal && (
        <CorrectionModal
          title="Delete Draft Correction Run"
          dangerLevel="medium"
          description={
            <DeleteDraftModalBody
              deleteReasonId={deleteReasonId}
              deleteDraftReason={deleteDraftReason}
              onReasonChange={setDeleteDraftReason}
              loading={deleteDraftLoading}
              sourcePayPeriodId={payPeriod.source_pay_period_id}
            />
          }
          errorMessage={deleteDraftError}
          confirmLabel={deleteDraftLoading ? 'Deleting…' : 'Delete Draft Correction Run'}
          confirmClassName="bg-orange-600 hover:bg-orange-700 focus:ring-orange-500 text-white"
          loading={deleteDraftLoading}
          confirmDisabled={deleteDraftLoading}
          onConfirm={handleDeleteDraftSubmit}
          onCancel={closeDeleteDraftModal}
        />
      )}
    </div>
  );
}

// ----------------------------------------------------------------
// Error message helpers
// ----------------------------------------------------------------

/** Append next-step guidance to server errors for common known conditions. */
function buildErrorWithRecovery(msg: string): string {
  const lower = msg.toLowerCase();

  if (lower.includes('already been voided') || lower.includes('already voided')) {
    return `${msg} — Refresh the page to see the current state. If this period was voided by another operator, check the correction history.`;
  }
  if (lower.includes('already has a correction run') || lower.includes('already superseded')) {
    return `${msg} — Refresh the page to find the existing correction run, or view Correction History below.`;
  }
  if (lower.includes('not committed') || lower.includes('must be committed')) {
    return `${msg} — Only committed pay periods can be voided. Go back and commit the period first.`;
  }
  if (lower.includes('not voided') || lower.includes('must be voided')) {
    return `${msg} — Void the source period first before creating a correction run.`;
  }
  if (lower.includes('network') || lower.includes('fetch')) {
    return `${msg} — Check your network connection and try again. No changes were made.`;
  }
  return `${msg} — If this error persists, contact support with the pay period ID.`;
}

// ----------------------------------------------------------------
// Modal body sub-components
// ----------------------------------------------------------------

interface VoidModalBodyProps {
  isCorrection: boolean;
  voidReasonId: string;
  voidConfirmId: string;
  voidReason: string;
  voidConfirmText: string;
  onReasonChange: (v: string) => void;
  onConfirmTextChange: (v: string) => void;
  loading: boolean;
}

function VoidModalBody({
  isCorrection,
  voidReasonId,
  voidConfirmId,
  voidReason,
  voidConfirmText,
  onReasonChange,
  onConfirmTextChange,
  loading,
}: VoidModalBodyProps) {
  return (
    <>
      <div className="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 mb-4" role="note">
        <p className="font-semibold mb-1">⚠️ This action cannot be undone.</p>
        {isCorrection ? (
          <ul className="list-disc list-inside space-y-1 text-red-700">
            <li>This committed correction run will be permanently voided.</li>
            <li>All YTD totals updated by this correction run will be reversed.</li>
            <li>The source period will be re-opened for a new correction run.</li>
            <li>Issued checks for this correction run should be destroyed.</li>
          </ul>
        ) : (
          <ul className="list-disc list-inside space-y-1 text-red-700">
            <li>All YTD totals for every employee in this period will be reversed.</li>
            <li>Issued checks for this period should be destroyed.</li>
            <li>A correction run can be created afterward to reprocess payroll.</li>
            <li>This is the correct path per the Cornerstone payroll correction runbook.</li>
          </ul>
        )}
      </div>

      <label htmlFor={voidReasonId} className="block text-sm font-medium text-gray-700 mb-1">
        Reason for voiding <span className="text-red-500" aria-hidden="true">*</span>
        <span className="sr-only">(required, minimum 10 characters)</span>
      </label>
      <textarea
        id={voidReasonId}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-red-400 focus:border-red-400 disabled:bg-gray-100 disabled:text-gray-400"
        rows={3}
        placeholder="e.g. Employee 'Jane Doe' was included in error — she was on unpaid leave this period"
        value={voidReason}
        disabled={loading}
        aria-required="true"
        onChange={(e) => onReasonChange(e.target.value)}
      />
      <p className="mt-0.5 text-xs text-gray-400">
        Minimum {MIN_REASON_LENGTH} characters. This is recorded permanently in the audit trail.
      </p>

      <label
        htmlFor={voidConfirmId}
        className="block text-sm font-medium text-gray-700 mt-4 mb-1"
      >
        Type <strong>VOID</strong> to confirm this irreversible action
      </label>
      <input
        id={voidConfirmId}
        type="text"
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm font-mono focus:ring-2 focus:ring-red-400 focus:border-red-400 disabled:bg-gray-100"
        placeholder="VOID"
        value={voidConfirmText}
        disabled={loading}
        aria-required="true"
        autoComplete="off"
        onChange={(e) => onConfirmTextChange(e.target.value)}
      />
    </>
  );
}

interface CreateCorrectionModalBodyProps {
  corrReasonId: string;
  corrPayDateId: string;
  correctionReason: string;
  correctionPayDate: string;
  onReasonChange: (v: string) => void;
  onPayDateChange: (v: string) => void;
  loading: boolean;
}

function CreateCorrectionModalBody({
  corrReasonId,
  corrPayDateId,
  correctionReason,
  correctionPayDate,
  onReasonChange,
  onPayDateChange,
  loading,
}: CreateCorrectionModalBodyProps) {
  return (
    <>
      <div className="rounded-md border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800 mb-4" role="note">
        <p className="font-semibold mb-1">What happens next:</p>
        <ol className="list-decimal list-inside space-y-1 text-amber-700">
          <li>A new <strong>draft pay period</strong> will be created, pre-populated with the same employees as the voided period.</li>
          <li>You will be taken to the correction run where you can adjust hours, bonuses, and deductions.</li>
          <li>Calculate and review, then commit when ready. YTD totals will be updated on commit.</li>
        </ol>
      </div>

      <label
        htmlFor={corrReasonId}
        className="block text-sm font-medium text-gray-700 mb-1"
      >
        Reason for correction <span className="text-red-500" aria-hidden="true">*</span>
        <span className="sr-only">(required, minimum 10 characters)</span>
      </label>
      <textarea
        id={corrReasonId}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-amber-400 focus:border-amber-400 disabled:bg-gray-100 disabled:text-gray-400"
        rows={3}
        placeholder="e.g. Overtime hours were entered as regular hours for 3 employees — correcting to proper OT rate"
        value={correctionReason}
        disabled={loading}
        aria-required="true"
        onChange={(e) => onReasonChange(e.target.value)}
      />
      <p className="mt-0.5 text-xs text-gray-400">
        Minimum {MIN_REASON_LENGTH} characters. Describe the specific error being corrected.
      </p>

      <label
        htmlFor={corrPayDateId}
        className="block text-sm font-medium text-gray-700 mt-4 mb-1"
      >
        Pay date for correction run{' '}
        <span className="text-gray-400 font-normal">(optional — defaults to original pay date)</span>
      </label>
      <input
        id={corrPayDateId}
        type="date"
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-amber-400 focus:border-amber-400 disabled:bg-gray-100"
        value={correctionPayDate}
        disabled={loading}
        onChange={(e) => onPayDateChange(e.target.value)}
      />
      <p className="mt-0.5 text-xs text-gray-400">
        Use an updated pay date if replacement checks need to be dated differently from the original.
      </p>
    </>
  );
}

interface DeleteDraftModalBodyProps {
  deleteReasonId: string;
  deleteDraftReason: string;
  onReasonChange: (v: string) => void;
  loading: boolean;
  sourcePayPeriodId: number | null | undefined;
}

function DeleteDraftModalBody({
  deleteReasonId,
  deleteDraftReason,
  onReasonChange,
  loading,
  sourcePayPeriodId,
}: DeleteDraftModalBodyProps) {
  return (
    <>
      <div className="rounded-md border border-orange-200 bg-orange-50 px-4 py-3 text-sm text-orange-800 mb-4" role="note">
        <p className="font-semibold mb-1">What happens when you delete this draft correction run:</p>
        <ul className="list-disc list-inside space-y-1 text-orange-700">
          <li>This draft correction run will be permanently deleted.</li>
          <li>
            Source period{sourcePayPeriodId ? ` #${sourcePayPeriodId}` : ''} will be
            re-opened for a new correction run.
          </li>
          <li>No YTD totals are affected — this draft was never committed.</li>
          <li>You can immediately create a new correction run on the source period.</li>
        </ul>
        <p className="mt-2 text-orange-700">
          <strong>Use this when:</strong> you created a correction run by mistake, or need to start over with different dates or a different setup.
        </p>
      </div>

      <label
        htmlFor={deleteReasonId}
        className="block text-sm font-medium text-gray-700 mb-1"
      >
        Reason for deleting this draft <span className="text-red-500" aria-hidden="true">*</span>
        <span className="sr-only">(required, minimum 10 characters)</span>
      </label>
      <textarea
        id={deleteReasonId}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-orange-400 focus:border-orange-400 disabled:bg-gray-100 disabled:text-gray-400"
        rows={3}
        placeholder="e.g. Created with the wrong pay date — need to recreate with the correct date of 03/28/2026"
        value={deleteDraftReason}
        disabled={loading}
        aria-required="true"
        onChange={(e) => onReasonChange(e.target.value)}
      />
      <p className="mt-0.5 text-xs text-gray-400">
        Minimum {MIN_REASON_LENGTH} characters. Recorded in the audit trail on the source period.
      </p>
    </>
  );
}

// ----------------------------------------------------------------
// CorrectionEventRow — audit timeline entry
// ----------------------------------------------------------------

interface CorrectionEventRowProps {
  event: PayPeriodCorrectionEvent;
  index: number;
  total: number;
  deletedRunIds: Set<number>;
}

function CorrectionEventRow({ event, index, total, deletedRunIds }: CorrectionEventRowProps) {
  const navigate = useNavigate();
  const label   = ACTION_LABELS[event.action_type] ?? event.action_type;
  const variant = ACTION_BADGE_VARIANTS[event.action_type] ?? 'default';
  const snap    = event.financial_snapshot ?? {};
  const desc    = ACTION_DESCRIPTIONS[event.action_type];

  const metadata    = (event.metadata ?? {}) as Record<string, unknown>;
  const createdRunId = typeof metadata.created_correction_run_id === 'number'
    ? metadata.created_correction_run_id : null;
  const deletedRunId = typeof metadata.deleted_correction_run_id === 'number'
    ? metadata.deleted_correction_run_id : null;

  const linkedRunId = event.resulting_pay_period_id ?? createdRunId;
  const shouldRenderLink = linkedRunId !== null && !deletedRunIds.has(linkedRunId);
  const runIdForDisplay = deletedRunId ?? linkedRunId;
  const showDeletedMessage =
    runIdForDisplay !== null &&
    event.action_type === 'correction_run_created' &&
    !shouldRenderLink;

  return (
    <li
      className="px-4 py-4 text-sm"
      aria-label={`Event ${index} of ${total}: ${label}`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          {/* Header row */}
          <div className="flex items-center gap-2 flex-wrap">
            {/* Timeline indicator */}
            <span
              className="inline-flex items-center justify-center w-5 h-5 rounded-full bg-gray-200 text-gray-500 text-xs font-semibold flex-shrink-0"
              aria-hidden="true"
            >
              {index}
            </span>
            <Badge variant={variant}>{label}</Badge>
            <span className="text-gray-500 text-xs">
              <time dateTime={event.created_at}>
                {new Date(event.created_at).toLocaleString()}
              </time>
            </span>
            {event.actor_name && (
              <span className="text-gray-500 text-xs">by {event.actor_name}</span>
            )}
          </div>

          {/* Description */}
          {desc && (
            <p className="mt-1.5 text-xs text-gray-500 italic">{desc}</p>
          )}

          {/* Reason */}
          <p className="mt-1 text-gray-700">
            <strong>Reason:</strong> {event.reason}
          </p>

          {/* Linkage — correction run created */}
          {shouldRenderLink && linkedRunId && (
            <p className="mt-1 text-gray-600 text-xs flex items-center gap-1">
              <span>→ Correction run:</span>
              <button
                className="underline text-blue-600 hover:text-blue-800 focus:outline-none focus:ring-2 focus:ring-blue-400 rounded"
                onClick={() => navigate(`/pay-periods/${linkedRunId}`)}
              >
                Period #{linkedRunId}
              </button>
            </p>
          )}

          {/* Linkage — correction run deleted */}
          {showDeletedMessage ? (
            <p className="mt-1 text-gray-500 text-xs">
              Draft correction run #{runIdForDisplay} was deleted before committing.
            </p>
          ) : null}
        </div>

        {/* Financial snapshot */}
        {snap.gross_pay !== undefined && (
          <div
            className="text-right text-xs text-gray-500 whitespace-nowrap bg-gray-100 rounded px-2 py-1"
            aria-label="Financial snapshot at time of event"
          >
            <div>Gross: {formatCurrency(snap.gross_pay ?? 0)}</div>
            <div>Net: {formatCurrency(snap.net_pay ?? 0)}</div>
            {snap.employee_count !== undefined && (
              <div>
                {snap.employee_count} employee
                {snap.employee_count !== 1 ? 's' : ''}
              </div>
            )}
          </div>
        )}
      </div>
    </li>
  );
}

// ----------------------------------------------------------------
// CorrectionModal — accessible inline dialog
// ----------------------------------------------------------------

type DangerLevel = 'high' | 'medium';

interface CorrectionModalProps {
  title: string;
  dangerLevel: DangerLevel;
  description: ReactNode;
  errorMessage: string | null;
  confirmLabel: string;
  confirmClassName: string;
  loading: boolean;
  confirmDisabled: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

function CorrectionModal({
  title,
  dangerLevel,
  description,
  errorMessage,
  confirmLabel,
  confirmClassName,
  loading,
  confirmDisabled,
  onConfirm,
  onCancel,
}: CorrectionModalProps) {
  const titleId       = useId();
  const descriptionId = useId();
  const panelRef      = useRef<HTMLDivElement | null>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);

  // Capture focus when dialog opens; restore when it closes
  useEffect(() => {
    returnFocusRef.current = document.activeElement as HTMLElement | null;
    // Small delay so the DOM is fully mounted before focusing
    const t = setTimeout(() => panelRef.current?.focus(), 10);
    return () => {
      clearTimeout(t);
      returnFocusRef.current?.focus?.();
    };
  }, []);

  // Keyboard: Escape closes (unless in-flight), Tab traps focus inside dialog
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !loading) {
        e.preventDefault();
        onCancel();
        return;
      }

      if (e.key === 'Tab' && panelRef.current) {
        const focusable = panelRef.current.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
        );
        if (focusable.length === 0) {
          e.preventDefault();
          return;
        }

        const first = focusable[0];
        const last  = focusable[focusable.length - 1];
        const active = document.activeElement as HTMLElement | null;

        if (e.shiftKey) {
          if (!active || active === first || !panelRef.current.contains(active)) {
            e.preventDefault();
            last.focus();
          }
        } else if (!active || active === last || !panelRef.current.contains(active)) {
          e.preventDefault();
          first.focus();
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [loading, onCancel]);

  const headerBorderClass =
    dangerLevel === 'high'
      ? 'border-red-200 bg-red-50'
      : 'border-amber-200 bg-amber-50';
  const titleClass =
    dangerLevel === 'high' ? 'text-red-900' : 'text-amber-900';

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      role="presentation"
      onClick={(e) => {
        if (e.target === e.currentTarget && !loading) onCancel();
      }}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={descriptionId}
        tabIndex={-1}
        className="w-full max-w-lg rounded-xl bg-white shadow-2xl outline-none"
      >
        {/* Header */}
        <div className={`border-b px-6 py-4 flex items-center justify-between gap-3 rounded-t-xl ${headerBorderClass}`}>
          <h3 id={titleId} className={`text-lg font-semibold ${titleClass}`}>
            {title}
          </h3>
          <button
            type="button"
            aria-label="Close dialog"
            className="text-gray-500 hover:text-gray-700 rounded p-1 focus:ring-2 focus:ring-gray-400 outline-none"
            onClick={onCancel}
            disabled={loading}
          >
            <span aria-hidden="true" className="text-xl leading-none">×</span>
          </button>
        </div>

        {/* Body */}
        <div className="px-6 py-5 max-h-[60vh] overflow-y-auto">
          <div id={descriptionId}>{description}</div>

          {errorMessage && (
            <div
              role="alert"
              aria-live="assertive"
              className="mt-4 text-sm text-red-700 rounded-md bg-red-50 border border-red-200 px-3 py-2"
            >
              <p className="font-medium mb-0.5">Action failed</p>
              <p>{errorMessage}</p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex justify-end gap-3 border-t px-6 py-4">
          <Button
            variant="outline"
            onClick={onCancel}
            disabled={loading}
          >
            Cancel
          </Button>
          <button
            type="button"
            className={`rounded-md px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-1 disabled:opacity-60 disabled:cursor-not-allowed ${confirmClassName}`}
            onClick={onConfirm}
            disabled={confirmDisabled}
            aria-busy={loading}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
