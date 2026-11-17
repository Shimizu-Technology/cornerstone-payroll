import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import { Link } from 'react-router';
import { RecordCreatorLine } from './RecordCreatorLine';
import { useAuth } from '@/contexts/AuthContext';
import type { RecordCreatorInfo } from '@/services/api';
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

type RecordActivityType = 'employees' | 'pay_periods' | 'companies';

interface RecordActivityTimelineProps {
  companyId: number;
  recordId: number;
  recordType: RecordActivityType;
  title?: string;
  description?: string;
}

const PAGE_SIZE = 20;
const DETAIL_LINE_LIMIT = 10;

interface Milestone {
  label: string;
  badgeClass: string;
  dotClass: string;
}

// Run milestones stand out so approve → roll back → approve again reads as
// separate steps in the story.
const MILESTONES: Record<string, Milestone> = {
  'pay_periods#approve': {
    label: 'Approved',
    badgeClass: 'border-success-200 bg-success-50 text-success-800',
    dotClass: 'border-success-600 bg-success-600',
  },
  'pay_periods#unapprove': {
    label: 'Approval rolled back',
    badgeClass: 'border-warning-300 bg-warning-50 text-warning-900',
    dotClass: 'border-warning-500 bg-warning-500',
  },
  'pay_periods#commit': {
    label: 'Committed',
    badgeClass: 'border-primary-200 bg-primary-50 text-primary-800',
    dotClass: 'border-primary-600 bg-primary-600',
  },
  'pay_periods#void': {
    label: 'Voided',
    badgeClass: 'border-danger-200 bg-danger-50 text-danger-800',
    dotClass: 'border-danger-600 bg-danger-600',
  },
};

export function RecordActivityTimeline({
  companyId,
  recordId,
  recordType,
  title = 'Complete activity history',
  description = 'Every recorded change to this record, with the person, time, and values involved.',
}: RecordActivityTimelineProps): ReactElement {
  const { hasCapability } = useAuth();
  const [creator, setCreator] = useState<RecordCreatorInfo | null>(null);
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [includeReportDetails, setIncludeReportDetails] = useState(false);
  const [hiddenReportDetails, setHiddenReportDetails] = useState(0);
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
        ...(includeReportDetails ? { include_report_details: true } : {}),
      }, companyId);
      if (requestId !== requestIdRef.current) return;

      setCreator(response.creator ?? null);
      setLogs((current) => {
        if (!append) return response.data;

        const seen = new Set(current.map((log) => log.id));
        return [...current, ...response.data.filter((log) => !seen.has(log.id))];
      });
      setPage(response.meta.current_page);
      setTotalPages(response.meta.total_pages || 1);
      setHiddenReportDetails(response.meta.hidden_report_detail_count ?? 0);
    } catch (loadError) {
      if (requestId !== requestIdRef.current) return;
      setError(loadError instanceof Error ? loadError.message : 'Activity history could not be loaded.');
    } finally {
      if (requestId === requestIdRef.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [companyId, includeReportDetails, recordId, recordType]);

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
            {!loading && !error && <RecordCreatorLine creator={creator} />}
            {hasCapability('view_audit_history') && (
              <Link className="mt-2 inline-block text-sm font-medium text-primary-700 underline" to={`/settings/audit-logs?record_type=${recordType}&record_id=${recordId}&company_id=${companyId}`}>View in Activity History</Link>
            )}
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
            {(hiddenReportDetails > 0 || includeReportDetails) && (
              <div className="border-t border-neutral-100 px-4 py-3 text-sm text-neutral-600 sm:px-6">
                {includeReportDetails
                  ? 'Showing transmittal and sign-off detail loads.'
                  : `${hiddenReportDetails} transmittal and sign-off detail ${hiddenReportDetails === 1 ? 'load is' : 'loads are'} hidden. Every report opened or downloaded is still listed.`}
                {' '}
                <button
                  type="button"
                  className="inline-flex min-h-11 items-center font-medium text-primary-700 underline sm:min-h-0"
                  onClick={() => setIncludeReportDetails((current) => !current)}
                >
                  {includeReportDetails ? 'Hide them' : 'Show them'}
                </button>
              </div>
            )}
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
  const milestone = MILESTONES[log.action];
  const detailLines = log.detail_lines ?? [];
  const changedCount = Number(log.metadata?.input_change_count ?? detailLines.length);
  const hiddenDetailLines = Math.max(changedCount, detailLines.length) - Math.min(detailLines.length, DETAIL_LINE_LIMIT);

  return (
    <li className="relative px-4 py-5 sm:px-6">
      <div className="grid gap-4 sm:grid-cols-[12px_minmax(0,1fr)_auto] sm:gap-5">
        <span className={`mt-1 hidden h-3 w-3 rounded-full border-[3px] sm:block ${milestone ? milestone.dotClass : 'border-primary-200 bg-white'}`} aria-hidden="true" />
        <div className="min-w-0">
          {milestone && (
            <span className={`mb-2 inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold ${milestone.badgeClass}`}>
              {milestone.label}
            </span>
          )}
          <p className="font-semibold leading-6 text-neutral-950">{displayAuditGroupAction(group)}</p>
          <p className="mt-1 text-sm text-neutral-500">
            {log.actor_email || (log.actor_role ? humanizeAuditKey(log.actor_role) : 'Actor details unavailable')}
          </p>
        </div>
        <time className="text-sm font-medium text-neutral-600 sm:text-right" dateTime={log.created_at}>
          {formatGuamDateTime(log.created_at)}
        </time>
      </div>

      {detailLines.length > 0 && (
        <ul className="mt-3 space-y-1 text-sm text-neutral-700 sm:ml-8">
          {detailLines.slice(0, DETAIL_LINE_LIMIT).map((line) => <li key={line} className="break-words">{line}</li>)}
          {hiddenDetailLines > 0 && <li className="text-neutral-500">and {hiddenDetailLines} more</li>}
        </ul>
      )}

      {facts.length > 0 && (
        <p className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-sm text-neutral-600 sm:ml-8">
          {facts.map((fact) => <span key={fact.label}>{fact.label}: <strong className="font-semibold text-neutral-800">{fact.value}</strong></span>)}
        </p>
      )}

      <div className="mt-4 sm:ml-8"><AuditEventDetails group={group} /></div>
    </li>
  );
}
