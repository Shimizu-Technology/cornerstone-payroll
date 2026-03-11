/**
 * CPR-71: Payroll Correction Panel
 *
 * Displayed on committed pay periods. Provides:
 *   - Void action (with required reason, explicit confirmation)
 *   - Create correction run action (with required reason)
 *   - Correction history / audit trail display
 */
import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { payPeriodsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type { PayPeriod, PayPeriodCorrectionEvent } from '@/types';

interface CorrectionPanelProps {
  payPeriod: PayPeriod;
  onPayPeriodChange: (updated: PayPeriod) => void;
}

const ACTION_LABELS: Record<string, string> = {
  void_initiated:            'Period Voided',
  correction_run_created:    'Correction Run Created',
  correction_run_committed:  'Correction Run Committed',
};

const ACTION_BADGE_VARIANTS: Record<string, 'default' | 'danger' | 'warning' | 'success' | 'info'> = {
  void_initiated:            'danger',
  correction_run_created:    'warning',
  correction_run_committed:  'success',
};

export function CorrectionPanel({ payPeriod, onPayPeriodChange }: CorrectionPanelProps) {
  const navigate = useNavigate();

  // Void modal state
  const [showVoidModal, setShowVoidModal] = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const [voidConfirmText, setVoidConfirmText] = useState('');
  const [voidLoading, setVoidLoading] = useState(false);
  const [voidError, setVoidError] = useState<string | null>(null);

  // Correction run modal state
  const [showCorrectionModal, setShowCorrectionModal] = useState(false);
  const [correctionReason, setCorrectionReason] = useState('');
  const [correctionPayDate, setCorrectionPayDate] = useState(payPeriod.pay_date ?? '');
  const [correctionLoading, setCorrectionLoading] = useState(false);
  const [correctionError, setCorrectionError] = useState<string | null>(null);

  // Correction history state
  const [historyEvents, setHistoryEvents] = useState<PayPeriodCorrectionEvent[] | null>(null);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);

  // ----------------------------------------------------------------
  // Void
  // ----------------------------------------------------------------
  const handleVoidSubmit = async () => {
    if (!voidReason.trim()) {
      setVoidError('A reason is required.');
      return;
    }
    if (voidConfirmText !== 'VOID') {
      setVoidError('Type VOID to confirm.');
      return;
    }

    try {
      setVoidLoading(true);
      setVoidError(null);
      const response = await payPeriodsApi.void(payPeriod.id, { reason: voidReason.trim() });
      onPayPeriodChange(response.pay_period);
      setShowVoidModal(false);
      setVoidReason('');
      setVoidConfirmText('');
      // Auto-load history after void
      loadHistory();
    } catch (err) {
      setVoidError(err instanceof Error ? err.message : 'Failed to void pay period.');
    } finally {
      setVoidLoading(false);
    }
  };

  // ----------------------------------------------------------------
  // Correction Run
  // ----------------------------------------------------------------
  const handleCorrectionSubmit = async () => {
    if (!correctionReason.trim()) {
      setCorrectionError('A reason is required.');
      return;
    }

    try {
      setCorrectionLoading(true);
      setCorrectionError(null);
      const response = await payPeriodsApi.createCorrectionRun(payPeriod.id, {
        reason:   correctionReason.trim(),
        pay_date: correctionPayDate || undefined,
      });
      onPayPeriodChange(response.source_pay_period);
      setShowCorrectionModal(false);
      setCorrectionReason('');
      // Navigate to the new correction run
      navigate(`/pay-periods/${response.correction_run.id}`);
    } catch (err) {
      setCorrectionError(err instanceof Error ? err.message : 'Failed to create correction run.');
    } finally {
      setCorrectionLoading(false);
    }
  };

  // ----------------------------------------------------------------
  // Correction History
  // ----------------------------------------------------------------
  const loadHistory = async () => {
    try {
      setHistoryLoading(true);
      setHistoryError(null);
      const response = await payPeriodsApi.correctionHistory(payPeriod.id);
      setHistoryEvents(response.correction_events);
      setHistoryOpen(true);
    } catch (err) {
      setHistoryError(err instanceof Error ? err.message : 'Failed to load correction history.');
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
  const isVoided     = payPeriod.correction_status === 'voided';
  const isCorrection = payPeriod.correction_status === 'correction';
  const canVoid      = payPeriod.can_void === true;
  const canCorrect   = payPeriod.can_create_correction_run === true;

  const closeVoidModal = useCallback(() => setShowVoidModal(false), []);
  const closeCorrectionModal = useCallback(() => setShowCorrectionModal(false), []);

  return (
    <div className="space-y-4">

      {/* Correction status badge */}
      {isVoided && (
        <div className="rounded-lg border border-red-200 bg-red-50 p-4">
          <div className="flex items-start gap-3">
            <span className="text-2xl">⚠️</span>
            <div className="flex-1">
              <p className="font-semibold text-red-800">This pay period has been voided</p>
              {payPeriod.void_reason && (
                <p className="mt-1 text-sm text-red-700">
                  <strong>Reason:</strong> {payPeriod.void_reason}
                </p>
              )}
              {payPeriod.voided_at && (
                <p className="mt-0.5 text-xs text-red-500">
                  Voided {new Date(payPeriod.voided_at).toLocaleString()}
                </p>
              )}
              {payPeriod.superseded_by_id && (
                <p className="mt-1 text-sm text-red-700">
                  Superseded by{' '}
                  <button
                    className="font-medium underline text-red-800 hover:text-red-900"
                    onClick={() => navigate(`/pay-periods/${payPeriod.superseded_by_id}`)}
                  >
                    correction run #{payPeriod.superseded_by_id}
                  </button>
                </p>
              )}
            </div>
          </div>
        </div>
      )}

      {isCorrection && payPeriod.source_pay_period_id && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 p-4">
          <p className="text-sm font-medium text-amber-800">
            🔁 This is a correction run for{' '}
            <button
              className="underline hover:text-amber-900"
              onClick={() => navigate(`/pay-periods/${payPeriod.source_pay_period_id}`)}
            >
              pay period #{payPeriod.source_pay_period_id}
            </button>
          </p>
        </div>
      )}

      {/* Action buttons */}
      <div className="flex flex-wrap gap-2">
        {canVoid && (
          <Button
            variant="outline"
            className="border-red-300 text-red-700 hover:bg-red-50 hover:border-red-400"
            onClick={() => {
              setShowVoidModal(true);
              setVoidError(null);
              setVoidReason('');
              setVoidConfirmText('');
            }}
          >
            Void This Period
          </Button>
        )}

        {canCorrect && (
          <Button
            variant="outline"
            className="border-amber-300 text-amber-700 hover:bg-amber-50 hover:border-amber-400"
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

        <Button
          variant="outline"
          size="sm"
          onClick={toggleHistory}
          disabled={historyLoading}
        >
          {historyLoading ? 'Loading…' : historyOpen ? 'Hide History' : 'View Correction History'}
        </Button>
      </div>

      {historyError && (
        <p className="text-sm text-red-600">{historyError}</p>
      )}

      {/* Correction History */}
      {historyOpen && historyEvents !== null && (
        <div className="rounded-lg border border-gray-200 bg-gray-50">
          <div className="border-b px-4 py-3">
            <h4 className="font-semibold text-gray-800 text-sm">Correction History</h4>
          </div>
          {historyEvents.length === 0 ? (
            <p className="px-4 py-6 text-sm text-gray-500 text-center">
              No correction events for this pay period.
            </p>
          ) : (
            <ul className="divide-y divide-gray-100">
              {historyEvents.map((event) => (
                <CorrectionEventRow key={event.id} event={event} />
              ))}
            </ul>
          )}
        </div>
      )}

      {/* ---- Void Modal ---- */}
      {showVoidModal && (
        <CorrectionModal
          title="Void Pay Period"
          description={
            <>
              <p className="text-sm text-gray-700 mb-3">
                Voiding a committed pay period will{' '}
                <strong>reverse all YTD totals</strong> for every employee in this period.
                This action cannot be undone. A correction run can be created afterward to re-process payroll.
              </p>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Reason <span className="text-red-500">*</span>
              </label>
              <textarea
                className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-red-400 focus:border-red-400"
                rows={3}
                placeholder="Describe why this pay period is being voided…"
                value={voidReason}
                onChange={(e) => setVoidReason(e.target.value)}
              />
              <label className="block text-sm font-medium text-gray-700 mt-3 mb-1">
                Type <strong>VOID</strong> to confirm
              </label>
              <input
                type="text"
                className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm font-mono focus:ring-2 focus:ring-red-400 focus:border-red-400"
                placeholder="VOID"
                value={voidConfirmText}
                onChange={(e) => setVoidConfirmText(e.target.value)}
              />
            </>
          }
          errorMessage={voidError}
          confirmLabel="Void Pay Period"
          confirmClassName="bg-red-600 hover:bg-red-700 text-white"
          loading={voidLoading}
          onConfirm={handleVoidSubmit}
          onCancel={closeVoidModal}
        />
      )}

      {/* ---- Correction Run Modal ---- */}
      {showCorrectionModal && (
        <CorrectionModal
          title="Create Correction Run"
          description={
            <>
              <p className="text-sm text-gray-700 mb-3">
                A new <strong>draft pay period</strong> will be created with the same employees as this voided period.
                You can adjust hours, re-calculate, and commit the correction run as a normal payroll.
              </p>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Reason <span className="text-red-500">*</span>
              </label>
              <textarea
                className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-amber-400 focus:border-amber-400"
                rows={3}
                placeholder="Describe what is being corrected…"
                value={correctionReason}
                onChange={(e) => setCorrectionReason(e.target.value)}
              />
              <label className="block text-sm font-medium text-gray-700 mt-3 mb-1">
                Pay Date (optional override)
              </label>
              <input
                type="date"
                className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:ring-2 focus:ring-amber-400 focus:border-amber-400"
                value={correctionPayDate}
                onChange={(e) => setCorrectionPayDate(e.target.value)}
              />
            </>
          }
          errorMessage={correctionError}
          confirmLabel="Create Correction Run"
          confirmClassName="bg-amber-600 hover:bg-amber-700 text-white"
          loading={correctionLoading}
          onConfirm={handleCorrectionSubmit}
          onCancel={closeCorrectionModal}
        />
      )}
    </div>
  );
}

// ---- Sub-components ----

interface CorrectionEventRowProps {
  event: PayPeriodCorrectionEvent;
}

function CorrectionEventRow({ event }: CorrectionEventRowProps) {
  const navigate = useNavigate();
  const label   = ACTION_LABELS[event.action_type] ?? event.action_type;
  const variant = ACTION_BADGE_VARIANTS[event.action_type] ?? 'default';
  const snap    = event.financial_snapshot ?? {};

  return (
    <li className="px-4 py-3 text-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <Badge variant={variant}>{label}</Badge>
            <span className="text-gray-500 text-xs">
              {new Date(event.created_at).toLocaleString()}
            </span>
            {event.actor_name && (
              <span className="text-gray-500 text-xs">by {event.actor_name}</span>
            )}
          </div>
          <p className="mt-1 text-gray-700">
            <strong>Reason:</strong> {event.reason}
          </p>
          {event.resulting_pay_period_id && (
            <p className="mt-0.5 text-gray-600 text-xs">
              Correction run:{' '}
              <button
                className="underline text-blue-600 hover:text-blue-800"
                onClick={() => navigate(`/pay-periods/${event.resulting_pay_period_id}`)}
              >
                Period #{event.resulting_pay_period_id}
              </button>
            </p>
          )}
        </div>
        {(snap.gross_pay !== undefined) && (
          <div className="text-right text-xs text-gray-500 whitespace-nowrap">
            <div>Gross: {formatCurrency(snap.gross_pay ?? 0)}</div>
            <div>Net: {formatCurrency(snap.net_pay ?? 0)}</div>
            {snap.employee_count !== undefined && (
              <div>{snap.employee_count} employee{snap.employee_count !== 1 ? 's' : ''}</div>
            )}
          </div>
        )}
      </div>
    </li>
  );
}

// Lightweight inline modal (no external dialog dependency needed here)
interface CorrectionModalProps {
  title: string;
  description: ReactNode;
  errorMessage: string | null;
  confirmLabel: string;
  confirmClassName: string;
  loading: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

function CorrectionModal({
  title,
  description,
  errorMessage,
  confirmLabel,
  confirmClassName,
  loading,
  onConfirm,
  onCancel,
}: CorrectionModalProps) {
  const titleId = useId();
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !loading) onCancel();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [loading, onCancel]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={(e) => {
        if (e.target === e.currentTarget && !loading) onCancel();
      }}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className="w-full max-w-md rounded-xl bg-white shadow-2xl"
      >
        <div className="border-b px-6 py-4">
          <h3 id={titleId} className="text-lg font-semibold text-gray-900">{title}</h3>
        </div>
        <div className="px-6 py-4">
          {description}
          {errorMessage && (
            <p className="mt-3 text-sm text-red-600 rounded-md bg-red-50 border border-red-200 px-3 py-2">
              {errorMessage}
            </p>
          )}
        </div>
        <div className="flex justify-end gap-3 border-t px-6 py-4">
          <Button variant="outline" onClick={onCancel} disabled={loading}>
            Cancel
          </Button>
          <button
            className={`rounded-md px-4 py-2 text-sm font-medium transition-colors disabled:opacity-60 ${confirmClassName}`}
            onClick={onConfirm}
            disabled={loading}
          >
            {loading ? 'Processing…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
