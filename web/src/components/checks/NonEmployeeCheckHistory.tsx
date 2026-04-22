import { useEffect, useState } from 'react';
import { nonEmployeeChecksApi } from '@/services/api';
import type { NonEmployeeCheckEdit } from '@/types';

interface NonEmployeeCheckHistoryProps {
  checkId: number;
}

const FIELD_LABELS: Record<string, string> = {
  payable_to: 'Payable To',
  amount: 'Amount',
  check_type: 'Check Type',
  check_number: 'Check #',
  reference_number: 'Reference #',
  memo: 'Memo',
  description: 'Description',
};

function formatValue(field: string, value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === '') return '—';
  if (field === 'amount') return `$${Number(value).toFixed(2)}`;
  return String(value);
}

export function NonEmployeeCheckHistory({ checkId }: NonEmployeeCheckHistoryProps) {
  const [edits, setEdits] = useState<NonEmployeeCheckEdit[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const requestTimer = window.setTimeout(() => {
      setLoading(true);
      setError(null);
      nonEmployeeChecksApi
        .history(checkId)
        .then(res => {
          if (cancelled) return;
          setEdits(res.history);
        })
        .catch(err => {
          if (cancelled) return;
          setError(err instanceof Error ? err.message : 'Failed to load history');
        })
        .finally(() => {
          if (!cancelled) setLoading(false);
        });
    }, 0);

    return () => {
      cancelled = true;
      window.clearTimeout(requestTimer);
    };
  }, [checkId]);

  if (loading) {
    return <p className="px-3 py-2 text-xs text-gray-500">Loading edit history…</p>;
  }

  if (error) {
    return <p className="px-3 py-2 text-xs text-red-600">{error}</p>;
  }

  if (!edits || edits.length === 0) {
    return <p className="px-3 py-2 text-xs italic text-gray-500">No edits yet.</p>;
  }

  return (
    <ol className="divide-y divide-gray-200">
      {edits.map(edit => (
        <li key={edit.id} className="px-3 py-2 text-xs">
          <div className="flex items-baseline justify-between gap-2">
            <span className="font-medium text-gray-900">
              {edit.edited_by_name || 'System'}
            </span>
            <span className="text-gray-500">
              {new Date(edit.created_at).toLocaleString()}
            </span>
          </div>
          {edit.reason && (
            <p className="mt-0.5 italic text-gray-600">“{edit.reason}”</p>
          )}
          <ul className="mt-1 space-y-0.5">
            {edit.changed_fields.map(field => (
              <li key={field} className="font-mono">
                <span className="text-gray-700">{FIELD_LABELS[field] || field}:</span>{' '}
                <span className="text-red-600 line-through">
                  {formatValue(field, edit.before[field])}
                </span>{' '}
                <span className="text-gray-400">→</span>{' '}
                <span className="text-green-700">
                  {formatValue(field, edit.after[field])}
                </span>
              </li>
            ))}
          </ul>
        </li>
      ))}
    </ol>
  );
}
