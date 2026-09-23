import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import { Activity, ChevronDown, Clock3, RefreshCw, TriangleAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AuditEventDetails } from '@/components/audit/AuditEventDetails';
import {
  auditBusinessFacts,
  displayAuditGroupAction,
  groupAuditEntries,
  humanizeAuditKey,
  type AuditEntryGroup,
} from '@/lib/audit-display';
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

  const groups = useMemo(() => groupAuditEntries(logs), [logs]);

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
              {groups.map((group) => <ActivityEntry key={group.key} group={group} />)}
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

function ActivityEntry({ group }: { group: AuditEntryGroup }): ReactElement {
  const log = group.primary;
  const facts = auditBusinessFacts(log).slice(0, 3);

  return (
    <li className="relative px-4 py-5 sm:px-6">
      <div className="grid gap-4 sm:grid-cols-[12px_minmax(0,1fr)_auto] sm:gap-5">
        <span className="mt-1 hidden h-3 w-3 rounded-full border-[3px] border-primary-200 bg-white sm:block" aria-hidden="true" />
        <div className="min-w-0">
          <p className="font-semibold leading-6 text-neutral-950">{displayAuditGroupAction(group)}</p>
          <p className="mt-1 text-sm text-neutral-500">
            {log.actor_email || (log.actor_role ? humanizeAuditKey(log.actor_role) : 'Actor details unavailable')}
          </p>
        </div>
        <time className="text-sm font-medium text-neutral-600 sm:text-right" dateTime={log.created_at}>
          {formatGuamDateTime(log.created_at)}
        </time>
      </div>

      {facts.length > 0 && (
        <p className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-sm text-neutral-600 sm:ml-8">
          {facts.map((fact) => <span key={fact.label}>{fact.label}: <strong className="font-semibold text-neutral-800">{fact.value}</strong></span>)}
        </p>
      )}

      <div className="mt-4 sm:ml-8"><AuditEventDetails group={group} /></div>
    </li>
  );
}
