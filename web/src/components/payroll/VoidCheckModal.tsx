import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
/**
 * CPR-66: VoidCheckModal
 * Confirms void with required written reason (10+ chars).
 */
import { useState } from 'react';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import type { CheckItem } from '@/types';
import { checksApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';

interface VoidCheckModalProps {
  item: CheckItem;
  operation?: 'void' | 'reverse';
  readOnly?: boolean;
  onClose: () => void;
  onComplete: () => Promise<void>;
}

export function VoidCheckModal({ item, operation = 'void', readOnly = false, onClose, onComplete }: VoidCheckModalProps) {
  const reversing = operation === 'reverse';
  const title = reversing ? 'Reverse paycheck' : 'Void Check';
  const [reason, setReason] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);

  const valid = reason.trim().length >= 10;

  const handleVoid = async () => {
    if (readOnly || !valid) return;
    setLoading(true);
    setError(null);
    try {
      await (reversing ? checksApi.reversePaycheck(item.id, reason.trim()) : checksApi.void(item.id, reason.trim()));
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : reversing ? 'Failed to reverse paycheck' : 'Failed to void check');
      setLoading(false);
    }
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !loading) onClose(); }} dismissOnEscape={!loading}>
      <DialogContent aria-label={title} className="dialog-center-mobile rounded-xl space-y-4">
        <div>
          <DialogTitle className="text-lg font-semibold text-red-700">{title} #{item.check_number}</DialogTitle>
          <p className="text-sm text-gray-600 mt-1">
            Employee: <span className="font-medium">{item.employee_name}</span> &mdash;{' '}
            Net pay:{' '}
            <span className="font-medium">
              {new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(item.net_pay)}
            </span>
          </p>
        </div>

        <div className="bg-red-50 border border-red-200 rounded-lg p-3 text-sm text-red-800">
          {reversing ? <>This reverses the earned wages, taxes, YTD and liabilities for this paycheck once. It does not recover money already paid. Enter the accounting reason. Connected source corrections and recorded payments must be reviewed separately.</> : <>The physical check is retired. Wages are still owed and stay in reports, taxes and YTD. Reissue a replacement, or use the separate Reverse paycheck action if the earned payroll itself was incorrect.</>}
        </div>

        <div className="space-y-1">
          <Label htmlFor="void-reason">
            {reversing ? 'Reversal reason' : 'Void reason'} <span className="text-red-500">*</span>
          </Label>
          <Textarea
            id="void-reason"
            placeholder={reversing ? "Explain why the earned payroll should be reversed" : "e.g., Paper jam — physical check damaged in printer"}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            className={`text-base sm:text-sm ${reason.length > 0 && !valid ? 'border-red-400' : ''}`}
          />
          {reason.length > 0 && !valid && (
            <p className="text-xs text-red-600">Reason must be at least 10 characters.</p>
          )}
          <p className="text-xs text-gray-500">{reason.trim().length} / 10 characters minimum</p>
        </div>

        {readOnly && <p role="status" className="text-sm text-amber-800">Changes are unavailable with your current workspace access. Your entered details remain here; Cancel is available.</p>}
        {error && (
          <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="outline" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleVoid}
            disabled={readOnly || !valid || loading}
            className="bg-red-600 hover:bg-red-700 text-white"
          >
            {loading ? 'Saving…' : title}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
