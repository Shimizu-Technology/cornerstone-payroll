/**
 * CPR-66: VoidCheckModal
 * Confirms void with required written reason (10+ chars).
 */
import { useState } from 'react';
import { createPortal } from 'react-dom';
import type { CheckItem } from '@/types';
import { checksApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';

interface VoidCheckModalProps {
  item: CheckItem;
  onClose: () => void;
  onComplete: () => Promise<void>;
}

export function VoidCheckModal({ item, onClose, onComplete }: VoidCheckModalProps) {
  const [reason, setReason] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const valid = reason.trim().length >= 10;

  const handleVoid = async () => {
    if (!valid) return;
    setLoading(true);
    setError(null);
    try {
      await checksApi.void(item.id, reason.trim());
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to void check');
      setLoading(false);
    }
  };

  return createPortal(
    <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-md p-6 space-y-4">
        <div>
          <h2 className="text-lg font-semibold text-red-700">Void Check #{item.check_number}</h2>
          <p className="text-sm text-gray-600 mt-1">
            Employee: <span className="font-medium">{item.employee_name}</span> &mdash;{' '}
            Net pay:{' '}
            <span className="font-medium">
              {new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(item.net_pay)}
            </span>
          </p>
        </div>

        <div className="bg-red-50 border border-red-200 rounded-lg p-3 text-sm text-red-800">
          <strong>This action cannot be undone.</strong> The check will be permanently voided.
          The payroll obligation remains in the system — only the physical check is voided.
          Use <em>Reprint</em> to issue a replacement.
        </div>

        <div className="space-y-1">
          <Label htmlFor="void-reason">
            Void Reason <span className="text-red-500">*</span>
          </Label>
          <Textarea
            id="void-reason"
            placeholder="e.g., Paper jam — physical check damaged in printer"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            className={`text-sm ${reason.length > 0 && !valid ? 'border-red-400' : ''}`}
          />
          {reason.length > 0 && !valid && (
            <p className="text-xs text-red-600">Reason must be at least 10 characters.</p>
          )}
          <p className="text-xs text-gray-500">{reason.trim().length} / 10 characters minimum</p>
        </div>

        {error && (
          <p className="text-sm text-red-600 bg-red-50 border border-red-200 rounded p-2">{error}</p>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="outline" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleVoid}
            disabled={!valid || loading}
            className="bg-red-600 hover:bg-red-700 text-white"
          >
            {loading ? 'Voiding…' : 'Void Check'}
          </Button>
        </div>
      </div>
    </div>,
    document.body
  );
}
