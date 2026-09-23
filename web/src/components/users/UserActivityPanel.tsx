import { useCallback, useEffect, useRef, useState, type ReactElement, type ReactNode } from 'react';
import {
  Activity,
  CheckCircle2,
  ChevronDown,
  Clock3,
  Loader2,
  LogIn,
  MonitorSmartphone,
  RefreshCw,
  ShieldCheck,
  UserRoundCog,
  X,
} from 'lucide-react';
import { auditLogsApi, type AuditLogEntry } from '@/services/api';
import type { User } from '@/types';
import { Button } from '@/components/ui/button';
import { formatGuamDateTime } from '@/lib/utils';
import { presentUserAgent } from '@/lib/user-agent';

interface UserActivityPanelProps {
  user: User;
  onClose: () => void;
}

type ActivityView = 'performed' | 'sign_ins' | 'account';

const PAGE_SIZE = 25;

function fallbackAction(action: string): string {
  return action.split('#').at(-1)?.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()) || action;
}

export function UserActivityPanel({ user, onClose }: UserActivityPanelProps): ReactElement {
  const [view, setView] = useState<ActivityView>('performed');
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestIdRef = useRef(0);

  const loadPage = useCallback(async (nextPage: number, append = false): Promise<void> => {
    const requestId = ++requestIdRef.current;
    if (append) setIsLoadingMore(true);
    else setIsLoading(true);
    setError(null);

    try {
      const response = await auditLogsApi.list({
        ...(view === 'performed'
          ? { user_id: user.id }
          : view === 'sign_ins'
            ? { user_id: user.id, event_action: 'authentication#signed_in', event_category: 'security' }
            : { record_type: 'users', record_id: user.id, action_filter: 'users#' }),
        page: nextPage,
        per_page: PAGE_SIZE,
        sort_direction: 'desc',
      });
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
      setError(loadError instanceof Error ? loadError.message : 'User activity could not be loaded.');
    } finally {
      if (requestId === requestIdRef.current) {
        setIsLoading(false);
        setIsLoadingMore(false);
      }
    }
  }, [user.id, view]);

  useEffect(() => {
    setLogs([]);
    setPage(1);
    setTotalPages(1);
    void loadPage(1);

    return () => {
      requestIdRef.current += 1;
    };
  }, [loadPage]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-neutral-950/35 backdrop-blur-[2px]" role="dialog" aria-modal="true" aria-label={`Activity for ${user.name}`}>
      <button className="absolute inset-0 cursor-default" onClick={onClose} aria-label="Close activity panel" />
      <section className="relative flex h-full w-full max-w-2xl animate-in flex-col bg-white shadow-2xl duration-300 slide-in-from-right">
        <header className="flex items-start justify-between border-b border-neutral-200 px-4 py-5 sm:px-6">
          <div className="min-w-0 pr-4">
            <div className="flex items-center gap-2 text-sm font-semibold text-primary-700">
              <Activity className="h-4 w-4" aria-hidden="true" /> User activity
            </div>
            <h2 className="mt-2 truncate text-2xl font-semibold tracking-tight text-neutral-950">{user.name}</h2>
            <p className="mt-1 truncate text-sm text-neutral-500">{user.email}</p>
          </div>
          <Button className="min-h-11 min-w-11" size="sm" variant="ghost" onClick={onClose} aria-label="Close">
            <X className="h-5 w-5" aria-hidden="true" />
          </Button>
        </header>

        <div className="grid grid-cols-2 gap-3 border-b border-neutral-200 bg-neutral-50 px-4 py-5 sm:grid-cols-4 sm:px-6">
          <Summary label="Last active" value={formatGuamDateTime(user.last_active_at)} />
          <Summary label="Last sign-in" value={formatGuamDateTime(user.last_login_at)} />
          <Summary label="Created" value={formatGuamDateTime(user.created_at)} />
          <Summary label="Created by" value={user.invited_by_name || 'Not recorded'} />
        </div>

        <div className="border-b border-neutral-200 px-4 pt-4 sm:px-6">
          <div className="overflow-x-auto pb-1">
            <div className="grid min-w-[33rem] grid-cols-3 rounded-xl bg-neutral-100 p-1 sm:min-w-0" role="tablist" aria-label="User history views">
              <Tab active={view === 'performed'} onClick={() => setView('performed')} icon={<Activity className="h-4 w-4" />} label="Actions performed" />
              <Tab active={view === 'sign_ins'} onClick={() => setView('sign_ins')} icon={<LogIn className="h-4 w-4" />} label="Sign-in history" />
              <Tab active={view === 'account'} onClick={() => setView('account')} icon={<UserRoundCog className="h-4 w-4" />} label="Account history" />
            </div>
          </div>
          <p className="py-3 text-xs leading-5 text-neutral-500">
            {view === 'performed'
              ? `Recorded actions ${user.name} performed across the system.`
              : view === 'sign_ins'
                ? `Successful sign-ins recorded when ${user.name} started a new Clerk session.`
                : `Changes administrators made to ${user.name}'s account, role, and access.`}
          </p>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5 sm:px-6 sm:py-6">
          {view === 'sign_ins' && <SignInScopeNotice />}
          <div className="mb-4 flex items-center gap-2">
            <Clock3 className="h-4 w-4 text-neutral-500" aria-hidden="true" />
            <h3 className="font-semibold text-neutral-950">
              {view === 'performed' ? 'Activity timeline' : view === 'sign_ins' ? 'Successful sign-ins' : 'Account timeline'}
            </h3>
          </div>

          {isLoading && logs.length === 0 ? (
            <LoadingState />
          ) : error && logs.length === 0 ? (
            <ErrorState message={error} onRetry={() => void loadPage(1)} />
          ) : logs.length === 0 ? (
            <EmptyState view={view} />
          ) : (
            <>
              <ol className="space-y-4">
                {logs.map((log) => view === 'sign_ins'
                  ? <SignInEntry key={log.id} log={log} />
                  : <ActivityEntry key={log.id} log={log} />)}
              </ol>
              {(page < totalPages || error) && (
                <div className="pt-5 text-center">
                  {error && <p className="mb-3 text-sm text-danger-700" role="alert">{error}</p>}
                  <Button
                    className="min-h-11 w-full sm:w-auto"
                    variant="outline"
                    disabled={isLoadingMore}
                    onClick={() => void loadPage(page + 1, true)}
                  >
                    {isLoadingMore
                      ? <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden="true" />
                      : <ChevronDown className="mr-2 h-4 w-4" aria-hidden="true" />}
                    {isLoadingMore ? 'Loading older activity…' : error ? 'Try loading older activity again' : 'Load older activity'}
                  </Button>
                </div>
              )}
            </>
          )}
        </div>
      </section>
    </div>
  );
}

function SignInScopeNotice(): ReactElement {
  return (
    <div className="mb-5 flex items-start gap-3 rounded-2xl border border-primary-100 bg-primary-50/60 p-4 text-sm leading-6 text-neutral-700">
      <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-primary-700" aria-hidden="true" />
      <div>
        <p className="font-semibold text-neutral-950">Successful sessions only</p>
        <p className="mt-1">
          Failed sign-in attempts are managed by Clerk and are not available in this history. Showing them here requires an authoritative Clerk log or webhook integration.
        </p>
      </div>
    </div>
  );
}

function SignInEntry({ log }: { log: AuditLogEntry }): ReactElement {
  const userAgent = presentUserAgent(log.user_agent);

  return (
    <li className="overflow-hidden rounded-2xl border border-neutral-200 bg-white">
      <div className="flex flex-col gap-3 border-b border-neutral-100 px-4 py-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex min-w-0 items-start gap-3">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-success-50 text-success-700">
            <CheckCircle2 className="h-5 w-5" aria-hidden="true" />
          </span>
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <p className="font-semibold text-neutral-950">Successful sign-in</p>
              <span className="rounded-full bg-success-50 px-2 py-0.5 text-xs font-bold text-success-700">Success</span>
            </div>
            <p className="mt-1 text-sm text-neutral-600">{userAgent.summary}</p>
          </div>
        </div>
        <time className="text-sm font-medium text-neutral-600 sm:text-right" dateTime={log.created_at}>
          {formatGuamDateTime(log.created_at)}
        </time>
      </div>

      <dl className="grid grid-cols-2 gap-px bg-neutral-100 sm:grid-cols-4">
        <SessionDetail label="IP address" value={log.ip_address || 'Not captured'} />
        <SessionDetail label="Browser" value={userAgent.browser} />
        <SessionDetail label="Platform" value={userAgent.platform} />
        <SessionDetail label="Device class" value={userAgent.deviceClass} />
      </dl>

      {(log.user_agent || log.request_id) && (
        <details className="group border-t border-neutral-100 px-3 py-2">
          <summary className="inline-flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-full px-2 text-sm font-semibold text-neutral-500 transition hover:bg-neutral-50 hover:text-neutral-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
            <ChevronDown className="h-4 w-4 transition-transform group-open:rotate-180" aria-hidden="true" />
            Technical details
          </summary>
          <dl className="mb-2 mt-1 grid gap-4 rounded-xl bg-neutral-50 p-4 text-sm">
            {log.user_agent && <TechnicalDetail label="Raw browser signature" value={log.user_agent} />}
            {log.request_id && <TechnicalDetail label="Request ID" value={log.request_id} />}
          </dl>
        </details>
      )}
    </li>
  );
}

function ActivityEntry({ log }: { log: AuditLogEntry }): ReactElement {
  return (
    <li className="relative border-l border-neutral-200 pl-5">
      <span className="absolute -left-1.5 top-1 h-3 w-3 rounded-full border-2 border-white bg-primary-600" aria-hidden="true" />
      <p className="font-medium text-neutral-950">{log.display_action || fallbackAction(log.action)}</p>
      <time className="mt-1 block text-sm text-neutral-500" dateTime={log.created_at}>
        {formatGuamDateTime(log.created_at)}{log.company_name ? ` · ${log.company_name}` : ''}
      </time>
      {log.display_subject && <p className="mt-2 text-sm text-neutral-600">Affected record: {log.display_subject}</p>}
    </li>
  );
}

function SessionDetail({ label, value }: { label: string; value: string }): ReactElement {
  return (
    <div className="min-w-0 bg-neutral-50 px-3 py-3 sm:px-4">
      <dt className="text-[11px] font-bold uppercase tracking-wide text-neutral-400">{label}</dt>
      <dd className="mt-1 break-words text-sm font-medium text-neutral-800">{value}</dd>
    </div>
  );
}

function TechnicalDetail({ label, value }: { label: string; value: string }): ReactElement {
  return (
    <div>
      <dt className="text-xs font-bold uppercase tracking-wide text-neutral-400">{label}</dt>
      <dd className="mt-1 break-all text-neutral-700">{value}</dd>
    </div>
  );
}

function LoadingState(): ReactElement {
  return (
    <div className="space-y-4 py-2" role="status" aria-label="Loading user activity">
      {[0, 1, 2].map((item) => (
        <div className="animate-pulse rounded-2xl border border-neutral-100 p-4" key={item}>
          <div className="h-4 w-2/3 rounded bg-neutral-100" />
          <div className="mt-3 h-3 w-1/3 rounded bg-neutral-100" />
        </div>
      ))}
    </div>
  );
}

function ErrorState({ message, onRetry }: { message: string; onRetry: () => void }): ReactElement {
  return (
    <div className="rounded-2xl border border-danger-100 bg-danger-50 p-6 text-center" role="alert">
      <p className="font-semibold text-danger-900">User activity could not be loaded</p>
      <p className="mt-2 text-sm text-danger-700">{message}</p>
      <Button className="mt-4 min-h-11" variant="outline" onClick={onRetry}>
        <RefreshCw className="mr-2 h-4 w-4" aria-hidden="true" /> Try again
      </Button>
    </div>
  );
}

function EmptyState({ view }: { view: ActivityView }): ReactElement {
  const signIns = view === 'sign_ins';
  return (
    <div className="flex min-h-56 flex-col items-center justify-center rounded-2xl border border-dashed border-neutral-300 p-6 text-center">
      <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-neutral-100 text-neutral-500">
        {signIns ? <MonitorSmartphone className="h-6 w-6" aria-hidden="true" /> : <Clock3 className="h-6 w-6" aria-hidden="true" />}
      </span>
      <p className="mt-4 font-semibold text-neutral-950">{signIns ? 'No successful sign-ins recorded yet' : 'No tracked activity yet'}</p>
      <p className="mt-2 max-w-md text-sm leading-6 text-neutral-500">
        {signIns
          ? 'A new entry will appear after this user starts a Clerk session and makes an authenticated request.'
          : 'New recorded changes will appear here.'}
      </p>
    </div>
  );
}

function Tab({ active, onClick, icon, label }: { active: boolean; onClick: () => void; icon: ReactNode; label: string }): ReactElement {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={`flex min-h-11 items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 ${active ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-500 hover:text-neutral-800'}`}
    >
      {icon}{label}
    </button>
  );
}

function Summary({ label, value }: { label: string; value: string }): ReactElement {
  return (
    <div className="min-w-0 rounded-xl border border-neutral-200 bg-white p-3">
      <p className="text-xs font-semibold uppercase tracking-[0.12em] text-neutral-500">{label}</p>
      <p className="mt-1 break-words text-sm font-medium text-neutral-900">{value}</p>
    </div>
  );
}
