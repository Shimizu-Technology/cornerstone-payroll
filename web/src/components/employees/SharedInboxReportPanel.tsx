import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import { AlertTriangle, Building2, CheckCircle2, Flag, FlagOff, MailWarning, RefreshCw, Trash2 } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Alert } from '@/components/ui/alert';
import {
  staffContactHygieneApi,
  type SharedEmailCompanySummary,
  type SharedEmailReportEntry,
  type SharedEmailReportResponse,
} from '@/services/staffContactHygieneApi';

interface SharedInboxReportPanelProps {
  activeCompanyId?: number;
  readOnly?: boolean;
  canManagePlaceholders?: boolean;
  onCleared?: (companyId: number, email: string, clearedCount: number) => void;
  onReportLoaded?: (report: SharedEmailReportResponse) => void;
}

interface PendingClearTarget {
  company: SharedEmailCompanySummary;
  entry: SharedEmailReportEntry;
}

const CLASSIFICATION_META: Record<SharedEmailReportEntry['classification'], { label: string; variant: 'danger' | 'warning' | 'info' }> = {
  shared_inbox: { label: 'Shared inbox', variant: 'danger' },
  placeholder: { label: 'Placeholder', variant: 'danger' },
  shared: { label: 'Duplicate candidate', variant: 'warning' },
};

const REASON_LABELS: Record<string, string> = {
  marked_placeholder: 'Marked placeholder',
  configured_placeholder: 'Configured placeholder',
  placeholder_pattern: 'Placeholder format',
  shared_across_companies: 'Shared across configurable companies',
  shared_within_company: 'Used by multiple employees',
};

export function SharedInboxReportPanel({
  activeCompanyId,
  readOnly = false,
  canManagePlaceholders = true,
  onCleared,
  onReportLoaded,
}: SharedInboxReportPanelProps): ReactElement {
  const [report, setReport] = useState<SharedEmailReportResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [pendingTarget, setPendingTarget] = useState<PendingClearTarget | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [clearError, setClearError] = useState<string | null>(null);
  const [markingEmail, setMarkingEmail] = useState<string | null>(null);
  const onReportLoadedRef = useRef(onReportLoaded);
  onReportLoadedRef.current = onReportLoaded;

  const loadReport = useCallback(async (): Promise<void> => {
    setLoading(true);
    setError(null);
    try {
      const response = await staffContactHygieneApi.sharedEmails();
      setReport(response);
      onReportLoadedRef.current?.(response);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not load the shared and placeholder email report.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadReport();
  }, [loadReport]);

  const openConfirmDialog = (company: SharedEmailCompanySummary, entry: SharedEmailReportEntry): void => {
    if (!entry.clearable || !canClearCompany(company.company_id)) return;
    setPendingTarget({ company, entry });
    setConfirmed(false);
    setClearError(null);
  };

  const closeConfirmDialog = (): void => {
    if (clearing) return;
    setPendingTarget(null);
    setConfirmed(false);
    setClearError(null);
  };

  const allowPlaceholderToggle = !readOnly && canManagePlaceholders && report?.can_manage_placeholders !== false;
  // Clear only the selected live client; a test workspace sees the report read-only.
  const canClearCompany = (companyId: number): boolean =>
    !readOnly && report?.can_clear !== false && companyId === activeCompanyId;

  const handleMarkPlaceholder = async (email: string): Promise<void> => {
    if (!allowPlaceholderToggle || markingEmail) return;
    setMarkingEmail(email);
    setError(null);
    try {
      const response = await staffContactHygieneApi.markPlaceholderEmail({ email });
      setSuccessMessage(response.message);
      await loadReport();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not mark this email as a placeholder.');
    } finally {
      setMarkingEmail(null);
    }
  };

  const handleUnmarkPlaceholder = async (email: string): Promise<void> => {
    if (!allowPlaceholderToggle || markingEmail) return;
    setMarkingEmail(email);
    setError(null);
    try {
      const response = await staffContactHygieneApi.unmarkPlaceholderEmail({ email });
      setSuccessMessage(response.message);
      await loadReport();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not remove this email from the placeholder list.');
    } finally {
      setMarkingEmail(null);
    }
  };

  const handleConfirmClear = async (): Promise<void> => {
    if (!pendingTarget || !confirmed || clearing) return;
    setClearing(true);
    setClearError(null);
    try {
      const response = await staffContactHygieneApi.clearSharedEmails({
        company_id: pendingTarget.company.company_id,
        email: pendingTarget.entry.email,
      }, pendingTarget.company.company_id);
      setSuccessMessage(response.message);
      const clearedCompanyId = pendingTarget.company.company_id;
      const clearedEmail = pendingTarget.entry.email;
      const clearedCount = response.data.cleared_count;
      setPendingTarget(null);
      setConfirmed(false);
      await loadReport();
      onCleared?.(clearedCompanyId, clearedEmail, clearedCount);
    } catch (caught) {
      setClearError(caught instanceof Error ? caught.message : 'Could not clear this email address.');
    } finally {
      setClearing(false);
    }
  };

  return (
    <div className="space-y-8">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="font-display text-xl font-bold tracking-tight text-neutral-950">Shared and placeholder emails</h2>
          <p className="mt-1 text-sm text-neutral-600">
            Summary counts by company across clients you configure. No employee names or other personal data are listed here. Unmarked duplicates stay warning-only so families can share; mark confirmed shared inboxes as placeholders before bulk-clearing one company at a time.
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => void loadReport()} loading={loading} loadingLabel="Refreshing">
          <RefreshCw className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
          Refresh report
        </Button>
      </div>

      {successMessage && (
        <Alert tone="success" className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-2">
            <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success-700" aria-hidden="true" />
            <span>{successMessage}</span>
          </div>
          <button
            type="button"
            onClick={() => setSuccessMessage(null)}
            className="shrink-0 text-xs font-semibold text-success-800 underline"
          >
            Dismiss
          </button>
        </Alert>
      )}

      {error && (
        <Alert tone="error" className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <span>{error}</span>
          <Button variant="outline" size="sm" onClick={() => void loadReport()}>
            Try again
          </Button>
        </Alert>
      )}

      {loading && !report ? (
        <div className="flex items-center justify-center py-12">
          <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary-600" />
        </div>
      ) : report ? (
        <>
          <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <SummaryStat label="Companies affected" value={report.summary.companies_affected} />
            <SummaryStat label="Flagged addresses" value={report.summary.distinct_flagged_emails} />
            <SummaryStat label="Employee records" value={report.summary.total_employee_records} />
            <SummaryStat label="Active employees" value={report.summary.active_employee_records} highlight={report.summary.active_employee_records > 0} />
          </div>

          {report.companies.length === 0 ? (
            <Card>
              <CardContent className="py-12 text-center">
                <CheckCircle2 className="mx-auto h-10 w-10 text-success-600" aria-hidden="true" />
                <h3 className="mt-4 text-base font-semibold text-neutral-900">No shared or placeholder emails found</h3>
                <p className="mt-1 text-sm text-neutral-600">
                  Every employee email across your configurable companies is unique and passes placeholder checks.
                </p>
              </CardContent>
            </Card>
          ) : (
            <div className="space-y-4">
              {report.companies.map((company) => {
                const isCurrent = activeCompanyId === company.company_id;
                return (
                  <Card key={company.company_id} className={isCurrent ? 'border-primary-300 ring-1 ring-primary-100' : undefined}>
                    <CardHeader className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <Building2 className="h-4 w-4 shrink-0 text-primary-700" aria-hidden="true" />
                          <CardTitle className="text-base">{company.company_name}</CardTitle>
                          {isCurrent && <Badge variant="info">Selected client</Badge>}
                        </div>
                        <CardDescription className="mt-1">
                          {company.total_flagged_records} flagged {company.total_flagged_records === 1 ? 'record' : 'records'} ({company.active_flagged_records} active)
                        </CardDescription>
                      </div>
                    </CardHeader>
                    <CardContent className="divide-y divide-neutral-200 p-0">
                      {company.emails.map((entry) => {
                        const meta = CLASSIFICATION_META[entry.classification] || CLASSIFICATION_META.shared;
                        const isMarking = markingEmail === entry.email;
                        return (
                          <div
                            key={`${company.company_id}-${entry.email}`}
                            className="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                          >
                            <div className="min-w-0 space-y-2">
                              <div className="flex flex-wrap items-center gap-2">
                                <MailWarning className="h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
                                <span className="break-all font-mono text-sm font-semibold text-neutral-950">{entry.email}</span>
                                <Badge variant={meta.variant}>{meta.label}</Badge>
                              </div>
                              <p className="text-sm text-neutral-700">
                                <span className="font-semibold tabular-nums">{entry.total_count}</span>{' '}
                                {entry.total_count === 1 ? 'employee record' : 'employee records'} at {company.company_name}{' '}
                                (<span className="tabular-nums">{entry.active_count}</span> active,{' '}
                                <span className="tabular-nums">{entry.inactive_count}</span> inactive)
                                {entry.companies_count > 1 && (
                                  <span className="text-neutral-500">
                                    {' '}· <span className="tabular-nums">{entry.organization_total_count}</span> across{' '}
                                    <span className="tabular-nums">{entry.companies_count}</span> configurable companies
                                  </span>
                                )}
                              </p>
                              <div className="flex flex-wrap gap-2">
                                {entry.reasons.map((reason) => (
                                  <span
                                    key={reason}
                                    className="rounded-md bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-600"
                                  >
                                    {REASON_LABELS[reason] || reason}
                                  </span>
                                ))}
                              </div>
                            </div>
                            <div className="flex shrink-0 flex-wrap items-center gap-2">
                              {entry.clearable ? (
                                <>
                                  {entry.unmarkable && allowPlaceholderToggle && (
                                    <Button
                                      variant="ghost"
                                      size="sm"
                                      disabled={Boolean(markingEmail)}
                                      loading={isMarking}
                                      loadingLabel="Updating..."
                                      onClick={() => void handleUnmarkPlaceholder(entry.email)}
                                    >
                                      <FlagOff className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
                                      Unmark
                                    </Button>
                                  )}
                                  {canClearCompany(company.company_id) ? (
                                    <Button
                                      variant="outline"
                                      size="sm"
                                      onClick={() => openConfirmDialog(company, entry)}
                                      className="w-full border-danger-200 text-danger-700 hover:border-danger-300 hover:bg-danger-50 hover:text-danger-800 sm:w-auto"
                                    >
                                      <Trash2 className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
                                      Clear to blank
                                    </Button>
                                  ) : (
                                    <span className="text-xs text-neutral-500">
                                      {report.can_clear === false
                                        ? "Test workspaces can't clear emails"
                                        : readOnly ? 'Clearing is off for this client' : 'Open this client to clear it'}
                                    </span>
                                  )}
                                </>
                              ) : allowPlaceholderToggle ? (
                                <Button
                                  variant="outline"
                                  size="sm"
                                  disabled={Boolean(markingEmail)}
                                  loading={isMarking}
                                  loadingLabel="Marking..."
                                  onClick={() => void handleMarkPlaceholder(entry.email)}
                                  className="w-full sm:w-auto"
                                >
                                  <Flag className="mr-2 h-3.5 w-3.5" aria-hidden="true" />
                                  Mark as placeholder
                                </Button>
                              ) : (
                                <span className="text-xs text-neutral-500">
                                  Org admin needed on a live client to mark
                                </span>
                              )}
                            </div>
                          </div>
                        );
                      })}
                    </CardContent>
                  </Card>
                );
              })}
            </div>
          )}
        </>
      ) : null}

      {report && (report.placeholder_marks?.length ?? 0) > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Marked as placeholders</CardTitle>
            <CardDescription className="mt-1">
              These addresses can&apos;t be saved on an employee. Unmark one to allow it again, even after every use was cleared.
            </CardDescription>
          </CardHeader>
          <CardContent className="divide-y divide-neutral-200 p-0">
            {report.placeholder_marks?.map((mark) => (
              <div
                key={mark.email}
                className="flex flex-col gap-2 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
              >
                <span className="break-all font-mono text-sm font-semibold text-neutral-950">{mark.email}</span>
                {mark.unmarkable && allowPlaceholderToggle ? (
                  <Button
                    variant="ghost"
                    size="sm"
                    disabled={Boolean(markingEmail)}
                    loading={markingEmail === mark.email}
                    loadingLabel="Updating..."
                    onClick={() => void handleUnmarkPlaceholder(mark.email)}
                    aria-label={`Unmark ${mark.email}`}
                  >
                    <FlagOff className="mr-2 h-4 w-4" aria-hidden="true" />
                    Unmark
                  </Button>
                ) : (
                  <span className="text-xs text-neutral-500">
                    {mark.unmarkable ? 'Org admin needed on a live client to unmark' : 'Set in server configuration'}
                  </span>
                )}
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      <Dialog open={Boolean(pendingTarget)} onOpenChange={(open) => { if (!open) closeConfirmDialog(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2 text-danger-800">
              <AlertTriangle className="h-5 w-5 shrink-0 text-danger-600" aria-hidden="true" />
              Clear placeholder email for {pendingTarget?.company.company_name}?
            </DialogTitle>
            <DialogDescription>
              This clears <span className="font-mono font-semibold text-neutral-900">{pendingTarget?.entry.email}</span> to blank on{' '}
              <span className="font-semibold text-neutral-900">{pendingTarget?.entry.total_count}</span>{' '}
              {pendingTarget?.entry.total_count === 1 ? 'employee record' : 'employee records'} (
              {pendingTarget?.entry.active_count} active, {pendingTarget?.entry.inactive_count} inactive) at{' '}
              <span className="font-semibold text-neutral-900">{pendingTarget?.company.company_name}</span> only.
            </DialogDescription>
          </DialogHeader>

          <div className="mt-4 space-y-4 text-sm text-neutral-700">
            <ul className="list-disc space-y-1 pl-4 text-neutral-600">
              <li>Email verification timestamps on those records are cleared.</li>
              <li>Cleared employees appear under Needs contact details so real addresses can be entered.</li>
              <li>Other companies with this address are not changed.</li>
              <li>This bulk clear is recorded in the company and employee activity logs.</li>
            </ul>

            <label className="flex cursor-pointer items-start gap-2 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
              <input
                type="checkbox"
                checked={confirmed}
                onChange={(event) => setConfirmed(event.target.checked)}
                className="mt-0.5 h-4 w-4 rounded border-neutral-300 text-danger-600 focus:ring-danger-500"
              />
              <span className="text-sm font-medium text-neutral-900">
                I confirm I want to clear this email to blank for {pendingTarget?.company.company_name}.
              </span>
            </label>

            {clearError && <Alert tone="error">{clearError}</Alert>}
          </div>

          <DialogFooter className="gap-2 sm:gap-0">
            <Button variant="outline" onClick={closeConfirmDialog} disabled={clearing}>
              Cancel
            </Button>
            <Button
              variant="danger"
              disabled={!confirmed || clearing}
              loading={clearing}
              loadingLabel="Clearing..."
              onClick={() => void handleConfirmClear()}
            >
              Clear {pendingTarget?.entry.total_count ?? 0} {pendingTarget?.entry.total_count === 1 ? 'record' : 'records'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function SummaryStat({ label, value, highlight = false }: { label: string; value: number; highlight?: boolean }): ReactElement {
  return (
    <div className={`rounded-xl border p-4 ${highlight ? 'border-warning-200 bg-warning-50/70' : 'border-neutral-200 bg-white'}`}>
      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-600">{label}</p>
      <p className={`mt-1 text-2xl font-extrabold tabular-nums ${highlight ? 'text-warning-900' : 'text-neutral-950'}`}>{value}</p>
    </div>
  );
}
