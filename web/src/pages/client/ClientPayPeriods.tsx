import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router';
import { Search } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi, type PayrollHistoryRecord, type ClientOpenPayrollPeriod } from '@/services/api';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import { currentAppPath, importedPayRunPath, payRunPath } from '@/lib/routes';
import { clientPayrollStatus, clientPayRunStatus } from '@/lib/clientPayrollStatus';
import { parsePositiveRouteId } from '@/lib/route-params';


function PeriodStatusBadge({ period }: { period: PayrollHistoryRecord }): ReactElement {
  return (
    <div className="space-y-1">
      <Badge variant={period.status === 'committed' ? 'success' : period.status === 'locked' ? 'warning' : 'default'}>
        {clientPayRunStatus(period)}
      </Badge>
      {period.can_decide_payroll_review && <p className="text-sm font-medium">Needs your approval</p>}
    </div>
  );
}

export function ClientPayPeriods(): ReactElement {
  const navigate = useNavigate();
  const location = useLocation();
  const { companyId: companyIdParam } = useParams<{ companyId: string }>();
  const companyId = parsePositiveRouteId(companyIdParam) ?? 0;
  const returnTo = currentAppPath(location.pathname, location.search);
  const [payPeriods, setPayPeriods] = useState<PayrollHistoryRecord[]>([]);
  const [openPeriodSummary, setOpenPeriodSummary] = useState<ClientOpenPayrollPeriod | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [search, setSearch] = useState('');
  const loadRequestIdRef = useRef(0);

  const load = useCallback(async (): Promise<void> => {
    const requestId = ++loadRequestIdRef.current;
    const isCurrentRequest = (): boolean => loadRequestIdRef.current === requestId;
    if (!Number.isInteger(companyId) || companyId <= 0) {
      setPayPeriods([]);
      setError('This pay-period list link is invalid.');
      setLoading(false);
      return;
    }
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.list(undefined, companyId);
      if (isCurrentRequest()) {
        setPayPeriods(response.pay_periods);
        setOpenPeriodSummary(response.open_period ?? null);
      }
    } catch (err) {
      if (isCurrentRequest()) setError(err instanceof Error ? err.message : 'Failed to load pay periods');
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [companyId, setError]);

  useLayoutEffect((): void => {
    loadRequestIdRef.current += 1;
    setOpenPeriodSummary(null);
    setPayPeriods([]);
    setError(null);
    setLoading(true);
  }, [companyId, setError]);

  useEffect((): (() => void) => {
    void load();
    return (): void => {
      loadRequestIdRef.current += 1;
    };
  }, [load]);

  const visiblePayPeriods = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return payPeriods;
    return payPeriods.filter((period) =>
      [
        formatDateRange(period.start_date, period.end_date),
        formatDate(period.pay_date),
        clientPayRunStatus(period),
        period.can_decide_payroll_review ? "Needs your approval" : "",
        period.test_workspace_role === 'baseline' ? 'Paid (copied history)' : null,
        period.source.label,
        period.source.detail,
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase()
        .includes(query)
    );
  }, [payPeriods, search]);

  const openPeriod = (period: PayrollHistoryRecord): void => {
    void navigate(period.record_type === 'imported'
      ? importedPayRunPath(companyId, period.id, { returnTo })
      : payRunPath(companyId, period.id, 'overview', { returnTo }));
  };

  return (
    <div>
      <Header title="Pay Periods" description="Review payroll runs and employee pay information." />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}
        {!error && !loading && openPeriodSummary && !openPeriodSummary.review_pay_period_id && (
          <Card className="space-y-2 p-4">
            <h2 className="font-semibold">{formatDateRange(openPeriodSummary.start_date, openPeriodSummary.end_date)}</h2>
            <p className="text-sm">Pay date {formatDate(openPeriodSummary.pay_date)} · {clientPayrollStatus(openPeriodSummary.client_payroll_status)}</p>
            <Link className="inline-flex min-h-11 items-center text-primary-800 underline" to={`/payroll-files/${encodeURIComponent(openPeriodSummary.ref)}`}>
              Open Pay Period Files
            </Link>
          </Card>
        )}

        <div className="flex flex-col gap-4 md:flex-row">
          <div className="relative max-w-md flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
            <Input className="pl-10" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search pay periods..." />
          </div>
        </div>

        {!error && <Card>
          {loading ? (
            <div className="py-12 text-center text-sm text-gray-500">Loading pay periods...</div>
          ) : visiblePayPeriods.length === 0 ? (
            <div className="py-12 text-center text-sm text-gray-500">No pay periods found.</div>
          ) : (
            <>
            <div className="space-y-3 p-3 lg:hidden">
              {visiblePayPeriods.map((period) => (
                <MobileRecordCard key={period.key}>
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-semibold text-neutral-950">{formatDateRange(period.start_date, period.end_date)}</p>
                      <p className="mt-1 text-sm text-neutral-600">Pay date {formatDate(period.pay_date, { weekday: 'short', year: undefined })}</p>
                    </div>
                    <PeriodStatusBadge period={period} />
                  </div>
                  <div className="mt-4 grid grid-cols-2 gap-3">
                    <MobileField label="Net pay" value={formatCurrency(period.total_net ?? 0)} />
                    <MobileField label="Gross pay" value={formatCurrency(period.total_gross ?? 0)} />
                    <MobileField label="Employees" value={period.employee_count} />
                    <MobileField label="Source" value={period.source.label} />
                  </div>
                  <Button className="mt-4 w-full" variant={period.can_decide_payroll_review ? 'primary' : 'outline'} onClick={() => openPeriod(period)}>
                    {period.can_decide_payroll_review ? 'Review & Approve' : 'View Payroll'}
                  </Button>
                </MobileRecordCard>
              ))}
            </div>
            <div className="hidden lg:block">
            <Table stickyHeader>
              <TableHeader>
                <TableRow>
                  <TableHead>Pay Period</TableHead>
                  <TableHead>Pay Date</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Gross Pay</TableHead>
                  <TableHead>Net Pay</TableHead>
                  <TableHead>Source</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody striped>
                {visiblePayPeriods.map((period) => (
                  <TableRow key={period.key}>
                    <TableCell className="font-medium text-gray-900">{formatDateRange(period.start_date, period.end_date)}</TableCell>
                    <TableCell>{formatDate(period.pay_date, { weekday: 'short', year: undefined })}</TableCell>
                    <TableCell>{period.employee_count}</TableCell>
                    <TableCell>{formatCurrency(period.total_gross ?? 0)}</TableCell>
                    <TableCell>{formatCurrency(period.total_net ?? 0)}</TableCell>
                    <TableCell><Badge variant={period.record_type === 'imported' ? 'warning' : 'default'}>{period.source.label}</Badge></TableCell>
                    <TableCell>
                      <PeriodStatusBadge period={period} />
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="ghost" size="sm" onClick={() => openPeriod(period)}>
                        {period.can_decide_payroll_review ? 'Review & Approve' : 'View'}
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            </div>
            </>
          )}
        </Card>}
      </div>
    </div>
  );
}
