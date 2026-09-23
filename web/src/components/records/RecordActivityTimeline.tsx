import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import { Activity, ChevronDown, Clock3, RefreshCw, ShieldCheck, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { displayAuditAction, formatAuditValue, humanizeAuditKey } from '@/lib/audit-display';
import { formatGuamDateTime } from '@/lib/utils';
import { recordActivitiesApi, type AuditLogEntry } from '@/services/api';

type RecordActivityType = 'employees' | 'pay_periods';

interface RecordActivityTimelineProps {
  companyId: number;
  recordId: number;
  recordType: RecordActivityType;
  title?: string;
  description?: string;
}

const PAGE_SIZE = 20;

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function valueMap(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

export function RecordActivityTimeline({
  companyId,
  recordId,
  recordType,
  title = 'Complete activity history',
  description = 'Every recorded change to this record, with the person, time, and values involved.',
}: RecordActivityTimelineProps): ReactElement {
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestIdRef = useRef(0);

  const loadPage = useCallback(async (nextPage: number, append: boolean): Promise<void> => {
    const requestId = ++requestIdRef.current;
    if (append) setLoadingMore(true);
    else setLoading(true);
    setError(null);

    try {
      const response = await recordActivitiesApi.list(recordType, recordId, {
        page: nextPage,
        per_page: PAGE_SIZE,
      }, companyId);
      if (requestId !== requestIdRef.current) return;

      setLogs((current) => {
        if (!append) return response.data;

        const seen = new Set(current.map((log) => log.id));
        return [...current, ...response.data.filter((log) => !seen.has(log.id))];
      });
      setPage(response.meta.current_page);
      setTotalPages(response.meta.total_pages || 1);
    } catch (loadError) {
      if (requestId !== requestIdRef.current) return;
      setError(loadError instanceof Error ? loadError.message : 'Activity history could not be loaded.');
    } finally {
      if (requestId === requestIdRef.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [companyId, recordId, recordType]);

  useEffect(() => {
    setLogs([]);
    setPage(1);
    setTotalPages(1);
    void loadPage(1, false);

    return () => {
      requestIdRef.current += 1;
    };
  }, [loadPage]);

  return (
    <Card>
      <CardHeader className="border-b border-neutral-100">
        <div className="flex items-start gap-3">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
            <Activity className="h-5 w-5" aria-hidden="true" />
          </span>
          <div>
            <CardTitle>{title}</CardTitle>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-neutral-500">{description}</p>
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        {loading ? (
          <div className="space-y-5 p-5" role="status" aria-label="Loading activity history">
            {[0, 1, 2].map((item) => (
              <div className="animate-pulse border-l-2 border-neutral-100 pl-5" key={item}>
                <div className="h-4 w-2/3 rounded bg-neutral-100" />
                <div className="mt-3 h-3 w-1/3 rounded bg-neutral-100" />
              </div>
            ))}
          </div>
        ) : error && logs.length === 0 ? (
          <div className="flex min-h-64 flex-col items-center justify-center px-6 py-10 text-center" role="alert">
            <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-danger-50 text-danger-700">
              <TriangleAlert className="h-6 w-6" aria-hidden="true" />
            </span>
            <p className="mt-4 font-semibold text-neutral-950">Activity history could not be loaded</p>
            <p className="mt-2 max-w-md text-sm leading-6 text-neutral-500">{error}</p>
            <Button className="mt-4" variant="outline" onClick={() => void loadPage(1, false)}>
              <RefreshCw className="mr-2 h-4 w-4" aria-hidden="true" />
              Try again
            </Button>
          </div>
        ) : logs.length === 0 ? (
          <div className="flex min-h-56 flex-col items-center justify-center px-6 py-10 text-center">
            <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-neutral-100 text-neutral-500">
              <Clock3 className="h-6 w-6" aria-hidden="true" />
            </span>
            <p className="mt-4 font-semibold text-neutral-950">No recorded activity yet</p>
            <p className="mt-2 max-w-md text-sm leading-6 text-neutral-500">New changes will appear here as they are recorded.</p>
          </div>
        ) : (
          <>
            <ol className="divide-y divide-neutral-100">
              {logs.map((log) => <ActivityEntry key={log.id} log={log} />)}
            </ol>
            {(page < totalPages || error) && (
              <div className="border-t border-neutral-100 p-4 text-center">
                {error && <p className="mb-3 text-sm text-danger-700" role="alert">{error}</p>}
                <Button
                  className="min-h-11"
                  variant="outline"
                  disabled={loadingMore}
                  onClick={() => void loadPage(page + 1, true)}
                >
                  <ChevronDown className="mr-2 h-4 w-4" aria-hidden="true" />
                  {loadingMore ? 'Loading older activity…' : error ? 'Try loading older activity again' : 'Load older activity'}
                </Button>
              </div>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}

function ActivityEntry({ log }: { log: AuditLogEntry }): ReactElement {
  const changedFields = stringList(log.metadata?.changed_fields).filter((field) => field !== 'id');
  const redactedFields = new Set(stringList(log.metadata?.redacted_fields));
  const beforeValues = valueMap(log.metadata?.before_values);
  const afterValues = valueMap(log.metadata?.after_values);
  const hasAdvancedDetails = Boolean(log.action || log.event_category || log.ip_address || log.request_id || log.user_agent);

  return (
    <li className="relative px-4 py-5 sm:px-6">
      <div className="grid gap-4 sm:grid-cols-[12px_minmax(0,1fr)_auto] sm:gap-5">
        <span className="mt-1 hidden h-3 w-3 rounded-full border-[3px] border-primary-200 bg-white sm:block" aria-hidden="true" />
        <div className="min-w-0">
          <p className="font-semibold leading-6 text-neutral-950">{displayAuditAction(log)}</p>
          <p className="mt-1 text-sm text-neutral-500">
            {log.actor_email || (log.actor_role ? humanizeAuditKey(log.actor_role) : 'Actor details unavailable')}
          </p>
        </div>
        <time className="text-sm font-medium text-neutral-600 sm:text-right" dateTime={log.created_at}>
          {formatGuamDateTime(log.created_at)}
        </time>
      </div>

      {changedFields.length > 0 && (
        <div className="mt-5 space-y-3 sm:ml-8">
          {changedFields.map((field) => (
            <div className="overflow-hidden rounded-xl border border-neutral-200" key={field}>
              <div className="border-b border-neutral-100 bg-neutral-50 px-4 py-2.5">
                <p className="text-xs font-extrabold uppercase tracking-[0.1em] text-neutral-500">{humanizeAuditKey(field)}</p>
              </div>
              {redactedFields.has(field) ? (
                <div className="flex items-start gap-3 px-4 py-4 text-sm leading-6 text-neutral-600">
                  <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
                  This value changed, but its contents are hidden to protect sensitive information.
                </div>
              ) : (
                <div className="grid sm:grid-cols-2">
                  <ValueCell label="Before" value={beforeValues[field]} />
                  <ValueCell className="border-t border-neutral-100 sm:border-l sm:border-t-0" label="After" value={afterValues[field]} />
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {hasAdvancedDetails && (
        <details className="group mt-4 sm:ml-8">
          <summary className="inline-flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-full px-3 text-sm font-semibold text-neutral-500 transition hover:bg-neutral-50 hover:text-neutral-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
            <ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" aria-hidden="true" />
            Technical details
          </summary>
          <dl className="mt-2 grid gap-x-6 gap-y-3 rounded-xl bg-neutral-50 p-4 text-sm sm:grid-cols-2">
            <TechnicalDetail label="Action" value={log.action} />
            <TechnicalDetail label="Category" value={humanizeAuditKey(log.event_category)} />
            <TechnicalDetail label="IP address" value={log.ip_address} />
            <TechnicalDetail label="Request ID" value={log.request_id} />
            <TechnicalDetail className="sm:col-span-2" label="Browser or device signature" value={log.user_agent} />
          </dl>
        </details>
      )}
    </li>
  );
}

function ValueCell({ label, value, className = '' }: { label: string; value: unknown; className?: string }): ReactElement {
  return (
    <div className={`px-4 py-3 ${className}`}>
      <p className="text-xs font-bold uppercase tracking-wide text-neutral-400">{label}</p>
      <p className="mt-1 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-800">{formatAuditValue(value)}</p>
    </div>
  );
}

function TechnicalDetail({ label, value, className = '' }: { label: string; value: string | null; className?: string }): ReactElement | null {
  if (!value) return null;
  return (
    <div className={className}>
      <dt className="text-xs font-bold uppercase tracking-wide text-neutral-400">{label}</dt>
      <dd className="mt-1 break-all text-neutral-700">{value}</dd>
    </div>
  );
}
