/**
 * CPR-66: ReprintCheckModal
 * Confirms reprint: voids the old check number, assigns a new one in-place.
 */
import { useState } from 'react';
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

export function ReprintCheckModal({ item, onClose, onComplete }: ReprintCheckModalProps) {
  const [reason, setReason] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleReprint = async () => {
    setLoading(true);
    setError(null);
    try {
      await checksApi.reprint(item.id, reason.trim() || undefined);
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to reprint check');
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-md p-6 space-y-4">
        {/* Header */}
        <div>
          <h2 className="text-lg font-semibold text-orange-700">Reprint Check #{item.check_number}</h2>
          <p className="text-sm text-gray-600 mt-1">
            Employee: <span className="font-medium">{item.employee_name}</span> &mdash;{' '}
            Net pay:{' '}
            <span className="font-medium">
              {new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(item.net_pay)}
            </span>
          </p>
        </div>

        {/* Info */}
        <div className="bg-orange-50 border border-orange-200 rounded-lg p-3 text-sm text-orange-800">
          <strong>What happens:</strong>
          <ul className="list-disc list-inside mt-1 space-y-1">
            <li>Check #{item.check_number} is recorded as voided in the audit trail</li>
            <li>A <strong>new check number</strong> is assigned from the company sequence</li>
            <li>The payroll amount is unchanged — this is a physical check replacement only</li>
            <li>The new check will appear as Unprinted, ready for printing</li>
          </ul>
        </div>

        {/* Optional reason */}
        <div className="space-y-1">
          <Label htmlFor="reprint-reason">Reason (optional)</Label>
          <Textarea
            id="reprint-reason"
            placeholder="e.g., Check lost in mail, paper jam, wrong name printed"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
            className="text-sm"
          />
        </div>

        {/* Error */}
        {error && (
          <p className="text-sm text-red-600 bg-red-50 border border-red-200 rounded p-2">{error}</p>
        )}

        {/* Actions */}
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="outline" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleReprint}
            disabled={loading}
            className="bg-orange-600 hover:bg-orange-700 text-white"
          >
            {loading ? 'Processing…' : 'Issue Replacement Check'}
          </Button>
        </div>
      </div>
    </div>
  );
}
