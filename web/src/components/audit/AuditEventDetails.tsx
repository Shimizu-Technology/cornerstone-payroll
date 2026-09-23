import { ChevronDown, ShieldCheck } from 'lucide-react';
import type { ReactElement, ReactNode } from 'react';
import {
  auditBusinessFacts,
  formatAuditValue,
  humanizeAuditKey,
  meaningfulAuditChanges,
  type AuditEntryGroup,
} from '@/lib/audit-display';
import { formatGuamDateTime } from '@/lib/utils';

interface AuditEventDetailsProps {
  group: AuditEntryGroup;
}

export function AuditEventDetails({ group }: AuditEventDetailsProps): ReactElement {
  const log = group.primary;
  const facts = auditBusinessFacts(log);
  const changes = meaningfulAuditChanges(log);
  const hasTechnicalEvidence = group.entries.some((entry) => Boolean(
    entry.action || entry.ip_address || entry.request_id || entry.user_agent
  ));

  return (
    <div className="space-y-3">
      {(facts.length > 0 || changes.length > 0) && (
        <Disclosure label="What happened">
          {facts.length > 0 && (
            <dl className="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-neutral-200 bg-neutral-200 sm:grid-cols-3">
              {facts.map((fact) => (
                <div className="bg-neutral-50 px-3 py-3" key={fact.label}>
                  <dt className="text-[11px] font-bold uppercase tracking-wide text-neutral-400">{fact.label}</dt>
                  <dd className="mt-1 text-sm font-semibold text-neutral-900">{fact.value}</dd>
                </div>
              ))}
            </dl>
          )}
          {changes.length > 0 && (
            <div className="mt-3 space-y-2">
              {changes.map((change) => (
                <div className="overflow-hidden rounded-xl border border-neutral-200" key={change.field}>
                  <p className="bg-neutral-50 px-3 py-2 text-xs font-extrabold uppercase tracking-[0.1em] text-neutral-500">
                    {humanizeAuditKey(change.field)}
                  </p>
                  {change.redacted ? (
                    <div className="flex items-start gap-3 border-t border-neutral-100 px-3 py-3 text-sm leading-6 text-neutral-600">
                      <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
                      This value changed, but its contents are hidden to protect sensitive information.
                    </div>
                  ) : (
                    <dl className="grid border-t border-neutral-100 sm:grid-cols-2">
                      <ValueCell label="Before" value={change.before} />
                      <ValueCell className="border-t border-neutral-100 sm:border-l sm:border-t-0" label="After" value={change.after} />
                    </dl>
                  )}
                </div>
              ))}
            </div>
          )}
        </Disclosure>
      )}

      {group.entries.length > 1 && (
        <Disclosure label={`${group.entries.length} access records`}>
          <ol className="divide-y divide-neutral-100 overflow-hidden rounded-xl border border-neutral-200">
            {group.entries.map((entry, index) => (
              <li className="px-3 py-3 text-sm" key={entry.id}>
                <div className="flex items-start justify-between gap-3">
                  <span className="font-medium text-neutral-800">Access {index + 1}</span>
                  <time className="text-right text-neutral-500" dateTime={entry.created_at}>{formatGuamDateTime(entry.created_at)}</time>
                </div>
                {entry.request_id && <p className="mt-1 break-all text-xs text-neutral-400">Request {entry.request_id}</p>}
              </li>
            ))}
          </ol>
        </Disclosure>
      )}

      {hasTechnicalEvidence && (
        <Disclosure label="Technical evidence">
          <div className="space-y-3 rounded-xl bg-neutral-50 p-4 text-sm">
            {group.entries.map((entry) => (
              <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2" key={entry.id}>
                <TechnicalDetail label="Action" value={entry.action} />
                <TechnicalDetail label="Category" value={humanizeAuditKey(entry.event_category)} />
                <TechnicalDetail label="IP address" value={entry.ip_address} />
                <TechnicalDetail label="Request ID" value={entry.request_id} />
                <TechnicalDetail className="sm:col-span-2" label="Browser or device signature" value={entry.user_agent} />
              </dl>
            ))}
          </div>
        </Disclosure>
      )}
    </div>
  );
}

function Disclosure({ label, children }: { label: string; children: ReactNode }): ReactElement {
  return (
    <details className="group rounded-xl border border-neutral-200 bg-white">
      <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 px-3 py-2 text-sm font-semibold text-neutral-700 transition hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-300">
        {label}
        <ChevronDown className="h-4 w-4 shrink-0 transition-transform group-open:rotate-180" aria-hidden="true" />
      </summary>
      <div className="border-t border-neutral-100 p-3">{children}</div>
    </details>
  );
}

function ValueCell({ label, value, className = '' }: { label: string; value: unknown; className?: string }): ReactElement {
  return (
    <div className={`px-3 py-3 ${className}`}>
      <dt className="text-xs font-bold uppercase tracking-wide text-neutral-400">{label}</dt>
      <dd className="mt-1 whitespace-pre-wrap break-words text-sm leading-6 text-neutral-800">{formatAuditValue(value)}</dd>
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
