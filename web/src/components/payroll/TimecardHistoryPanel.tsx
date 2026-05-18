import { useState, useEffect, useCallback } from 'react';
import { RotateCcw, RotateCw } from 'lucide-react';
import { Card } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { timecardsApi } from '@/services/api';
import type { TimecardData, PunchEntryData } from '@/services/api';

interface TimecardHistoryPanelProps {
  payPeriodId: number;
}

function formatTime(t: string | null | undefined): string {
  if (!t) return '—';
  const [h, m] = t.split(':').map(Number);
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 || 12;
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`;
}

type PunchTimeField = 'clock_in' | 'lunch_out' | 'lunch_in' | 'clock_out' | 'in3' | 'out3';

function parseTimeMinutes(value: string | null | undefined): number | null {
  if (!value) return null;
  const [hStr, mStr] = value.split(':');
  const hours = Number(hStr);
  const minutes = Number(mStr);
  if (!Number.isFinite(hours) || !Number.isFinite(minutes)) return null;
  if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null;
  return hours * 60 + minutes;
}

function calculatePunchHours(entry: Pick<PunchEntryData, PunchTimeField>): number | null {
  const clockIn = parseTimeMinutes(entry.clock_in);
  const lunchOut = parseTimeMinutes(entry.lunch_out);
  const lunchIn = parseTimeMinutes(entry.lunch_in);
  const clockOut = parseTimeMinutes(entry.clock_out);
  const in3 = parseTimeMinutes(entry.in3);
  const out3 = parseTimeMinutes(entry.out3);
  const pairs: Array<[number, number]> = [];

  if (lunchOut !== null && lunchIn !== null) {
    if (clockIn !== null) pairs.push([clockIn, lunchOut]);
    if (clockOut !== null) pairs.push([lunchIn, clockOut]);
  } else if (clockIn !== null && clockOut !== null) {
    pairs.push([clockIn, clockOut]);
  } else if (clockIn !== null && lunchOut !== null) {
    pairs.push([clockIn, lunchOut]);
  }
  if (in3 !== null && out3 !== null) pairs.push([in3, out3]);

  if (pairs.length === 0) return null;

  const totalMinutes = pairs.reduce((sum, [start, rawEnd]) => {
    const end = rawEnd < start ? rawEnd + 24 * 60 : rawEnd;
    return sum + end - start;
  }, 0);

  return Math.max(Math.round((totalMinutes / 60) * 100) / 100, 0);
}

function StatusBadge({ status }: { status: string }) {
  const colors: Record<string, string> = {
    reviewed: 'bg-green-100 text-green-700',
    complete: 'bg-blue-100 text-blue-700',
    processing: 'bg-yellow-100 text-yellow-700',
    pending: 'bg-gray-100 text-gray-600',
    failed: 'bg-red-100 text-red-700',
  };
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${colors[status] || 'bg-gray-100 text-gray-600'}`}>
      {status}
    </span>
  );
}

function PunchTable({ entries }: { entries: PunchEntryData[] }) {
  const activeEntries = entries.filter(e => !e.blank_day);
  if (activeEntries.length === 0) {
    return <p className="text-sm text-gray-400 italic py-2">No punch entries recorded</p>;
  }

  const totalHours = activeEntries.reduce((sum, e) => sum + (calculatePunchHours(e) ?? e.hours_worked ?? 0), 0);

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead>
          <tr className="border-b text-gray-500">
            <th className="text-left py-1.5 px-2 font-medium">Day</th>
            <th className="text-left py-1.5 px-2 font-medium">Date</th>
            <th className="text-center py-1.5 px-2 font-medium">In</th>
            <th className="text-center py-1.5 px-2 font-medium">Lunch Out</th>
            <th className="text-center py-1.5 px-2 font-medium">Lunch In</th>
            <th className="text-center py-1.5 px-2 font-medium">Out</th>
            <th className="text-right py-1.5 px-2 font-medium">Hours</th>
            <th className="text-center py-1.5 px-2 font-medium">Status</th>
          </tr>
        </thead>
        <tbody>
          {activeEntries.map((entry, index) => {
            const rowTone = index % 2 === 0 ? 'bg-white' : 'bg-slate-100';
            const attentionTone = index % 2 === 0 ? 'bg-amber-50' : 'bg-amber-100/70';
            const rowHours = calculatePunchHours(entry) ?? entry.hours_worked;
            return (
            <tr key={entry.id} className={`border-b border-gray-100 ${entry.needs_attention ? attentionTone : rowTone}`}>
              <td className="py-1.5 px-2 text-gray-500">{entry.day_of_week}</td>
              <td className="py-1.5 px-2">{entry.date || `Day ${entry.card_day}`}</td>
              <td className="py-1.5 px-2 text-center">{formatTime(entry.clock_in)}</td>
              <td className="py-1.5 px-2 text-center">{formatTime(entry.lunch_out)}</td>
              <td className="py-1.5 px-2 text-center">{formatTime(entry.lunch_in)}</td>
              <td className="py-1.5 px-2 text-center">{formatTime(entry.clock_out)}</td>
              <td className="py-1.5 px-2 text-right font-medium">{rowHours?.toFixed(2) ?? '—'}</td>
              <td className="py-1.5 px-2 text-center">
                {entry.review_state === 'approved' ? (
                  <span className="text-green-600">✓</span>
                ) : entry.needs_attention ? (
                  <span className="text-amber-600">⚠</span>
                ) : (
                  <span className="text-gray-300">—</span>
                )}
              </td>
            </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr className="border-t font-medium">
            <td colSpan={6} className="py-1.5 px-2 text-right text-gray-600">Total Hours:</td>
            <td className="py-1.5 px-2 text-right">{totalHours.toFixed(2)}</td>
            <td />
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

function TimecardCard({ timecard }: { timecard: TimecardData }) {
  const [expanded, setExpanded] = useState(false);
  const [imageExpanded, setImageExpanded] = useState(false);
  const [imageRotation, setImageRotation] = useState(0);

  const totalHours = timecard.punch_entries
    .filter(e => !e.blank_day)
    .reduce((sum, e) => sum + (calculatePunchHours(e) ?? e.hours_worked ?? 0), 0);

  return (
    <div className="border rounded-lg overflow-hidden">
      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center gap-3 p-3 hover:bg-gray-50 transition-colors text-left"
      >
        {timecard.image_url ? (
          <img
            src={timecard.image_url}
            alt="Timecard"
            className="w-12 h-16 object-cover rounded border shrink-0"
          />
        ) : (
          <div className="w-12 h-16 rounded border bg-gray-100 shrink-0 flex items-center justify-center">
            <svg className="w-5 h-5 text-gray-300" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909M3.75 21h16.5A2.25 2.25 0 0022.5 18.75V5.25A2.25 2.25 0 0020.25 3H3.75A2.25 2.25 0 001.5 5.25v13.5A2.25 2.25 0 003.75 21z" />
            </svg>
          </div>
        )}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-sm text-gray-900 truncate">
              {timecard.employee_name || 'Unknown Employee'}
            </span>
            <StatusBadge status={timecard.ocr_status} />
          </div>
          <div className="flex items-center gap-3 text-xs text-gray-500 mt-0.5">
            <span>{totalHours.toFixed(2)} hours</span>
            <span>{timecard.punch_entries.filter(e => !e.blank_day).length} entries</span>
            {timecard.reviewed_by_name && (
              <span className="text-green-600">Reviewed by {timecard.reviewed_by_name}</span>
            )}
          </div>
        </div>
        <svg
          className={`w-4 h-4 text-gray-400 transition-transform shrink-0 ${expanded ? 'rotate-180' : ''}`}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {expanded && (
        <div className="border-t bg-gray-50 p-3 space-y-3">
          {timecard.image_url && (
            <div>
              <button
                onClick={() => setImageExpanded(!imageExpanded)}
                className="text-xs text-blue-600 hover:text-blue-800 font-medium mb-1 flex items-center gap-1"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0zM10 7v3m0 0v3m0-3h3m-3 0H7" />
                </svg>
                {imageExpanded ? 'Collapse Image' : 'View Full Image'}
              </button>
              {imageExpanded && (
                <div className="space-y-2">
                  <div className="flex items-center gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      className="h-7 px-2 text-xs"
                      onClick={() => setImageRotation((value) => (value + 270) % 360)}
                    >
                      <RotateCcw className="h-3.5 w-3.5 mr-1" />
                      Rotate Left
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      className="h-7 px-2 text-xs"
                      onClick={() => setImageRotation((value) => (value + 90) % 360)}
                    >
                      <RotateCw className="h-3.5 w-3.5 mr-1" />
                      Rotate Right
                    </Button>
                    {imageRotation !== 0 && (
                      <Button
                        size="sm"
                        variant="outline"
                        className="h-7 px-2 text-xs"
                        onClick={() => setImageRotation(0)}
                      >
                        Reset
                      </Button>
                    )}
                  </div>
                  <div className="overflow-auto rounded border bg-white">
                    <img
                      src={timecard.image_url}
                      alt="Timecard full view"
                      className="max-w-full shadow-sm"
                      style={{
                        transform: `rotate(${imageRotation}deg)`,
                        transformOrigin: 'center center',
                      }}
                    />
                  </div>
                </div>
              )}
            </div>
          )}
          <PunchTable entries={timecard.punch_entries} />
          {timecard.overall_confidence != null && (
            <p className="text-xs text-gray-400">
              OCR Confidence: {(timecard.overall_confidence * 100).toFixed(0)}%
            </p>
          )}
        </div>
      )}
    </div>
  );
}

export function TimecardHistoryPanel({ payPeriodId }: TimecardHistoryPanelProps) {
  const [timecards, setTimecards] = useState<TimecardData[]>([]);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(false);

  const loadTimecards = useCallback(async () => {
    setLoading(true);
    try {
      const data = await timecardsApi.list(payPeriodId);
      setTimecards(data);
    } catch {
      setTimecards([]);
    } finally {
      setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => { loadTimecards(); }, [loadTimecards]);

  if (loading) {
    return (
      <Card>
        <div className="p-4 border-b bg-gray-50">
          <h3 className="font-semibold text-gray-900">Timecards</h3>
        </div>
        <div className="p-4 text-sm text-gray-500">Loading timecards...</div>
      </Card>
    );
  }

  if (timecards.length === 0) return null;

  const totalHours = timecards.reduce(
    (sum, tc) => sum + tc.punch_entries.filter(e => !e.blank_day).reduce((s, e) => s + (calculatePunchHours(e) ?? e.hours_worked ?? 0), 0),
    0
  );

  return (
    <Card>
      <div className="p-4 border-b bg-gray-50">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="font-semibold text-gray-900">Timecards</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              {timecards.length} timecard{timecards.length !== 1 ? 's' : ''} &middot; {totalHours.toFixed(2)} total hours
            </p>
          </div>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setExpanded(!expanded)}
            className="text-xs"
          >
            {expanded ? 'Collapse All' : 'Show Timecards'}
          </Button>
        </div>
      </div>
      {expanded && (
        <div className="p-4 space-y-2">
          {timecards.map(tc => (
            <TimecardCard key={tc.id} timecard={tc} />
          ))}
        </div>
      )}
    </Card>
  );
}
