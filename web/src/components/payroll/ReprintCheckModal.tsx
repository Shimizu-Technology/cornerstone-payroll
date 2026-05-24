/**
 * CPR-66: ReprintCheckModal
 * Confirms reissue: voids the old physical check number, assigns a new one in-place.
 */
import { useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import type { CheckItem } from '@/types';
import { checksApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';

interface ReprintCheckModalProps {
  item: CheckItem;
  onClose: () => void;
  onComplete: () => Promise<void>;
}

const reasonExamples = [
  'Lost check — stop payment requested at bank',
  'Damaged check stock',
  'Printer alignment issue',
  'Original check never received',
];

export function ReprintCheckModal({ item, onClose, onComplete }: ReprintCheckModalProps) {
  const [reason, setReason] = useState('');
  const [replacementCheckNumber, setReplacementCheckNumber] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const trimmedReason = reason.trim();
  const trimmedReplacementCheckNumber = replacementCheckNumber.trim();
  const replacementCheckNumberInvalid = trimmedReplacementCheckNumber.length > 0 && !/^\d+$/.test(trimmedReplacementCheckNumber);
  const canSubmit = trimmedReason.length > 0 && !replacementCheckNumberInvalid && !loading;
  const previousReissue = useMemo(() => {
    const reissues = item.events?.filter((event) => event.event_type === 'reprinted') || [];
    return reissues[reissues.length - 1];
  }, [item.events]);

  const handleReissue = async () => {
    if (!trimmedReason) {
      setError('Enter a reason before reissuing this check.');
      return;
    }

    if (replacementCheckNumberInvalid) {
      setError('Replacement check number must be numeric.');
      return;
    }

    setLoading(true);
    setError(null);
    try {
      await checksApi.reprint(item.id, trimmedReason, trimmedReplacementCheckNumber || undefined);
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to reissue check');
      setLoading(false);
    }
  };

  return createPortal(
    <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/50 p-4">
      <div className="w-full max-w-lg space-y-5 rounded-xl bg-white p-6 shadow-xl">
        <div>
          <h2 className="text-lg font-semibold text-orange-800">Reissue Check #{item.check_number}</h2>
          <p className="mt-1 text-sm text-gray-600">
            Employee: <span className="font-medium">{item.employee_name}</span> &mdash;{' '}
            Net pay:{' '}
            <span className="font-medium">
              {new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(item.net_pay)}
            </span>
          </p>
          {item.reprint_of_check_number && (
            <p className="mt-1 text-xs text-orange-700">
              Current check #{item.check_number} already replaced original check #{item.reprint_of_check_number}.
            </p>
          )}
        </div>

        <div className="rounded-lg border border-orange-200 bg-orange-50 p-3 text-sm text-orange-900">
          <strong>Physical check replacement only:</strong>
          <ul className="mt-1 list-inside list-disc space-y-1">
            <li>Check #{item.check_number} is recorded as voided in the check audit trail.</li>
            <li>Enter the replacement check number below, or leave it blank to use the next available company check number.</li>
            <li>Payroll wages, taxes, deductions, and net pay stay exactly the same.</li>
            <li>The replacement check appears as unprinted and ready for check stock.</li>
          </ul>
        </div>

        {previousReissue && (
          <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3 text-xs text-neutral-600">
            Last reissue event: check #{previousReissue.check_number} by {previousReissue.user_name || 'Unknown user'} on{' '}
            {new Date(previousReissue.created_at).toLocaleString()}.
          </div>
        )}

        <div className="space-y-2">
          <Label htmlFor="replacement-check-number">Replacement check number</Label>
          <input
            id="replacement-check-number"
            type="text"
            inputMode="numeric"
            placeholder="Leave blank to use next available"
            value={replacementCheckNumber}
            onChange={(e) => setReplacementCheckNumber(e.target.value)}
            className={`w-full rounded-xl border px-3.5 py-2.5 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-2 ${replacementCheckNumberInvalid ? 'border-red-400 focus-visible:ring-red-100' : 'border-neutral-300 focus-visible:border-primary-400 focus-visible:ring-primary-200'}`}
          />
          <p className="text-xs text-gray-500">
            Use this when you already know the physical check stock number being issued as the replacement.
          </p>
          {replacementCheckNumberInvalid && (
            <p className="text-xs text-red-600">Replacement check number must be numeric.</p>
          )}
        </div>

        <div className="space-y-2">
          <Label htmlFor="reissue-reason">Reason <span className="text-red-600">*</span></Label>
          <Textarea
            id="reissue-reason"
            placeholder="e.g., Lost check — stop payment requested at bank"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            className="text-sm"
          />
          <div className="flex flex-wrap gap-1.5">
            {reasonExamples.map((example) => (
              <button
                key={example}
                type="button"
                onClick={() => setReason(example)}
                className="rounded-full border border-orange-200 bg-white px-2.5 py-1 text-xs font-medium text-orange-800 hover:bg-orange-50"
              >
                {example}
              </button>
            ))}
          </div>
        </div>

        {error && (
          <p className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-600">{error}</p>
        )}

        <div className="flex justify-end gap-2 pt-1">
          <Button variant="outline" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleReissue}
            disabled={!canSubmit}
            className="bg-orange-600 text-white hover:bg-orange-700"
          >
            {loading ? 'Processing…' : 'Reissue Check'}
          </Button>
        </div>
      </div>
    </div>,
    document.body
  );
}
