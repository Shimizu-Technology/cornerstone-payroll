import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Activity, Clock3, Loader2, UserRoundCog, X } from 'lucide-react';
import { auditLogsApi, type AuditLogEntry } from '@/services/api';
import type { User } from '@/types';
import { Button } from '@/components/ui/button';

interface UserActivityPanelProps {
  user: User;
  onClose: () => void;
}

type ActivityView = 'performed' | 'account';

function formatDate(value?: string | null) {
  return value ? new Date(value).toLocaleString() : 'Not recorded';
}

function fallbackAction(action: string) {
  return action.split('#').at(-1)?.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()) || action;
}

export function UserActivityPanel({ user, onClose }: UserActivityPanelProps) {
  const [view, setView] = useState<ActivityView>('performed');
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const requestIdRef = useRef(0);

  const loadPage = useCallback(async (nextPage: number) => {
    const requestId = ++requestIdRef.current;
    setIsLoading(true);
    setError(null);
    try {
      const response = await auditLogsApi.list({
        ...(view === 'performed'
          ? { user_id: user.id }
          : { record_type: 'users', record_id: user.id, action_filter: 'users#' }),
        page: nextPage,
        per_page: 25,
        sort_direction: 'desc',
      });
      if (requestId !== requestIdRef.current) return;

      setLogs((current) => nextPage === 1 ? response.data : [...current, ...response.data]);
      setPage(nextPage);
      setTotalPages(response.meta.total_pages || 1);
    } catch (err) {
      if (requestId !== requestIdRef.current) return;
      setError(err instanceof Error ? err.message : 'Failed to load user activity');
    } finally {
      if (requestId === requestIdRef.current) setIsLoading(false);
    }
  }, [user.id, view]);

  useEffect(() => {
    setLogs([]);
    setPage(1);
    void loadPage(1);
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
      <section className="relative flex h-full w-full max-w-xl animate-in slide-in-from-right duration-300 flex-col bg-white shadow-2xl">
        <header className="flex items-start justify-between border-b border-neutral-200 px-6 py-5">
          <div>
            <div className="flex items-center gap-2 text-sm font-semibold text-primary-700">
              <Activity className="h-4 w-4" /> User activity
            </div>
            <h2 className="mt-2 text-2xl font-semibold tracking-tight text-neutral-950">{user.name}</h2>
            <p className="mt-1 text-sm text-neutral-500">{user.email}</p>
          </div>
          <Button size="sm" variant="ghost" onClick={onClose} aria-label="Close">
            <X className="h-5 w-5" />
          </Button>
        </header>

        <div className="grid grid-cols-2 gap-3 border-b border-neutral-200 bg-neutral-50 px-6 py-5">
          <Summary label="Last active" value={formatDate(user.last_active_at)} />
          <Summary label="Last sign-in" value={formatDate(user.last_login_at)} />
          <Summary label="Created" value={formatDate(user.created_at)} />
          <Summary label="Created by" value={user.invited_by_name || 'Not recorded'} />
        </div>

        <div className="border-b border-neutral-200 px-6 pt-4">
          <div className="grid grid-cols-2 rounded-xl bg-neutral-100 p-1" role="tablist" aria-label="User history views">
            <Tab active={view === 'performed'} onClick={() => setView('performed')} icon={<Activity className="h-4 w-4" />} label="Actions performed" />
            <Tab active={view === 'account'} onClick={() => setView('account')} icon={<UserRoundCog className="h-4 w-4" />} label="Account history" />
          </div>
          <p className="py-3 text-xs leading-5 text-neutral-500">
            {view === 'performed'
              ? `Everything ${user.name} did in the system, including sign-ins and payroll actions.`
              : `Changes other administrators made to ${user.name}'s account, role, and access.`}
          </p>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-6 py-6">
          <div className="mb-4 flex items-center gap-2">
            <Clock3 className="h-4 w-4 text-neutral-500" />
            <h3 className="font-semibold text-neutral-950">{view === 'performed' ? 'Activity timeline' : 'Account timeline'}</h3>
          </div>
          {error && <p className="rounded-xl bg-danger-50 p-3 text-sm text-danger-700">{error}</p>}
          {!isLoading && logs.length === 0 ? (
            <p className="rounded-2xl border border-dashed border-neutral-300 p-6 text-center text-sm text-neutral-500">
              No tracked activity exists in this view yet.
            </p>
          ) : (
            <ol className="space-y-4">
              {logs.map((log) => (
                <li key={log.id} className="relative border-l border-neutral-200 pl-5">
                  <span className="absolute -left-1.5 top-1 h-3 w-3 rounded-full border-2 border-white bg-primary-600" />
                  <p className="font-medium text-neutral-950">{log.display_action || fallbackAction(log.action)}</p>
                  <p className="mt-1 text-sm text-neutral-500">
                    {formatDate(log.created_at)}{log.company_name ? ` · ${log.company_name}` : ''}
                  </p>
                  {log.display_subject && (
                    <p className="mt-2 text-sm text-neutral-600">Affected record: {log.display_subject}</p>
                  )}
                </li>
              ))}
            </ol>
          )}
          {isLoading && (
            <div className="flex items-center justify-center py-6 text-sm text-neutral-500">
              <Loader2 className="mr-2 h-4 w-4 animate-spin" /> Loading activity...
            </div>
          )}
          {!isLoading && page < totalPages && (
            <Button className="mt-5 w-full" variant="outline" onClick={() => void loadPage(page + 1)}>
              Load older activity
            </Button>
          )}
        </div>
      </section>
    </div>
  );
}

function Tab({ active, onClick, icon, label }: { active: boolean; onClick: () => void; icon: ReactNode; label: string }) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={`flex items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-colors ${active ? 'bg-white text-neutral-950 shadow-sm' : 'text-neutral-500 hover:text-neutral-800'}`}
    >
      {icon}{label}
    </button>
  );
}

function Summary({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-neutral-200 bg-white p-3">
      <p className="text-xs font-semibold uppercase tracking-[0.12em] text-neutral-500">{label}</p>
      <p className="mt-1 text-sm font-medium text-neutral-900">{value}</p>
    </div>
  );
}
