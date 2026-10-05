import { useEffect, useState } from 'react';
import { Link, useLocation, useSearchParams } from 'react-router';
import { timeTrackingSourceHealthApi } from '@/services/api';
import type { ConnectorHealth, DeliveryHealth } from '@/lib/connector-health';
import { formatGuamDateTime } from '@/lib/utils';
import { payRunPath, payRunsPath } from '@/lib/routes';
import { Button } from '@/components/ui/button';

export function SourceConnectorHealth({ sourceId, companyId }: { sourceId: number; companyId: number }) {
  const [params, setParams] = useSearchParams();
  const location = useLocation();
  const expanded = params.get('connection_health') === 'open';
  const [health, setHealth] = useState<ConnectorHealth | null>(null);
  const [error, setError] = useState('');
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setHealth(null); setError('');
    if (expanded) void timeTrackingSourceHealthApi.read(sourceId, companyId, controller.signal).then(result => {
      if (controller.signal.aborted) return;
      if (result.source_id !== sourceId || result.company_id !== companyId || result.evidence_scope !== 'local_records') throw new Error('The connection review changed. Refresh before continuing.');
      setHealth(result);
    }).catch(caught => { if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : 'Connection review unavailable.'); });
    return () => controller.abort();
  }, [sourceId, companyId, expanded, retry]);
  const toggle = () => { const next = new URLSearchParams(params); next.set('source_id', String(sourceId)); if (expanded) next.delete('connection_health'); else next.set('connection_health', 'open'); setParams(next); };
  const returnParams = new URLSearchParams(params); returnParams.set('source_id', String(sourceId));
  const returnTo = `${location.pathname}?${returnParams}`;
  const links = (ids: number[]) => <div className="mt-2 flex flex-wrap gap-x-4 gap-y-2">{ids.map(id => <Link key={id} className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={payRunPath(companyId, id, 'work', { returnTo })}>Review pay run #{id}</Link>)}</div>;
  return <section className="rounded-xl border border-neutral-200 bg-white p-4 sm:p-5" aria-label="Connection delivery review">
    <Button variant="outline" aria-expanded={expanded} aria-controls="source-connector-health" onClick={toggle}>{expanded ? 'Hide connection review' : 'Review connection deliveries'}</Button>
    {expanded && <div id="source-connector-health" className="mt-4 space-y-4 text-sm">
      <p className="text-neutral-600">Stored Payroll records only. Delivery status describes synchronization with time tracking and does not establish unpaid money.</p>
      {error ? <div role="alert"><p>{error}</p><Button variant="outline" className="mt-2" onClick={() => setRetry(value => value + 1)}>Retry connection review</Button></div> : !health ? <p role="status">Loading stored delivery records…</p> : <>
        <p className="text-xs text-neutral-500">Reviewed {date(health.as_of)}. Last source activity recorded {date(health.last_source_activity_at)}.</p>
        {!health.active && <p className="font-semibold text-amber-800">Connection disabled. Retained delivery records remain available.</p>}
        <div className="grid gap-4 sm:grid-cols-2">{(['batch', 'entry'] as const).map(kind => <div key={kind} className="rounded-lg bg-neutral-50 p-3">
          <h3 className="font-semibold">{kind === 'batch' ? 'Batch receipts' : 'Entry receipts'}</h3><Receipt health={health.receipts[kind]} />{links(health.receipts[kind].pay_period_ids)}
        </div>)}</div>
        <div><h3 className="font-semibold">Calendar delivery</h3>
          {!health.calendar.supported && !health.calendar.recorded_period_count ? <p>Not supported by this connection.</p> : <>
            <p>{health.calendar.unacknowledged_revision_count} latest revisions awaiting acknowledgement · {health.calendar.failed_revision_count} failed</p>
            <p className="text-neutral-600">Last delivered {date(health.calendar.last_success_at)} · Oldest waiting {age(health.calendar.oldest_pending_age_seconds)}</p>{links(health.calendar.pay_period_ids)}
          </>}
        </div>
        <div><h3 className="font-semibold">Mapping review</h3>{health.latest_import_mapping_review.status === 'recorded' ? <>
          <p>{health.latest_import_mapping_review.missing_count} missing employee matches in the latest saved import preview.</p>
          <p className="text-neutral-600">Import recorded {date(health.latest_import_mapping_review.as_of)}; subsequent mapping changes may differ.</p>{links(health.latest_import_mapping_review.pay_period_id ? [health.latest_import_mapping_review.pay_period_id] : [])}
        </> : <p>No usable saved mapping preview. Current source roster counts are not fetched here.</p>}</div>
        <div><h3 className="font-semibold">Local reconciliation</h3><p>{health.reconciliation.pending_classification_count} classification reviews · {health.reconciliation.manual_pending_commit_count} manual links awaiting commit · {health.reconciliation.manual_sync_failed_count} manual sync failures</p>{links(health.reconciliation.pay_period_ids)}</div>
        <p className="text-neutral-600">Current source settlement holds and roster-wide missing mappings: not fetched. Open a pay run to review its current time tracking workspace.</p>
        <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={payRunsPath(companyId)}>Open pay runs</Link>
      </>}
    </div>}
  </section>;
}
function date(value?: string | null) { return value ? formatGuamDateTime(value) : 'not recorded'; }
function age(seconds: number | null) { return seconds == null ? 'none recorded' : seconds >= 86400 ? `${Math.floor(seconds / 86400)} days` : seconds >= 3600 ? `${Math.floor(seconds / 3600)} hours` : `${Math.floor(seconds / 60)} minutes`; }
function Receipt({ health }: { health: DeliveryHealth }) { return <>
  <p>{health.pending_count} pending · {health.failed_count} failed deliveries</p>
  <p className="text-neutral-600">Last successful delivery {date(health.last_success_at)} · Oldest waiting {age(health.oldest_pending_age_seconds)}</p>
  {health.failure_record_updated_at && <p className="text-neutral-600">Failure record updated {date(health.failure_record_updated_at)}</p>}
  {!health.recorded_count && <p className="text-neutral-600">No receipt deliveries recorded.</p>}
</>; }
