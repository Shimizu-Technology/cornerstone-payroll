import { useState, useRef, useEffect, type ReactNode } from 'react';
import { Link } from 'react-router';
import { MoreHorizontal } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow, TableFooter } from '@/components/ui/table';
import { formatCurrency } from '@/lib/utils';
import { employeePath } from '@/lib/routes';
import type { PayrollItem } from '@/types';
import type { PayRunSectionProps } from './usePayRunController';

type Props = Pick<PayRunSectionProps<'results'>, 'companyId' | 'currentPath' | 'isCalculated' | 'isCommitted' | 'payPeriod' | 'payrollItems' | 'sortPayrollItems' | 'registerTotals' | 'payrollItemDisplayedHours' | 'setReviewingItem' | 'setEditingItem' | 'setCorrectingItem' | 'setReplacingItem'> & { filters: ReactNode; fullDetail: ReactNode; primaryAction?: ReactNode };
const preferenceKey = 'payroll.results.tax-detail';

export function PayRunResultsView(props: Props) {
  const { companyId, currentPath, isCalculated, isCommitted, payPeriod, payrollItems, sortPayrollItems, registerTotals, payrollItemDisplayedHours, setReviewingItem, setEditingItem, setCorrectingItem, setReplacingItem, filters, fullDetail } = props;
  const [showTaxDetail, setShowTaxDetail] = useState(() => { try { return localStorage.getItem(preferenceKey) === 'true'; } catch { return false; } });
  const [filtersOpen, setFiltersOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const closeOutside = (event: PointerEvent) => root.current?.querySelectorAll<HTMLDetailsElement>('details[data-result-menu][open]').forEach(menu => { if (!menu.contains(event.target as Node)) menu.open = false; });
    document.addEventListener('pointerdown', closeOutside);
    return () => document.removeEventListener('pointerdown', closeOutside);
  }, []);
  const money = (value: unknown) => formatCurrency(Number(value) || 0);
  const hours = (item: PayrollItem): ReactNode => {
    const displayed = payrollItemDisplayedHours(item);
    const hasSalaryTimekeeping = Boolean(item.timekeeping_source)
      || Number(item.hours_worked || 0) > 0 || Number(item.overtime_hours || 0) > 0;
    if (item.employment_type === 'salary' && !hasSalaryTimekeeping) {
      return payPeriod.includes_base_salary === false
        ? <span className="text-neutral-600" title="Salary hours do not apply to this run">—</span>
        : <span className="whitespace-normal text-xs font-medium text-warning-700" title="No salary timekeeping record was available for this payroll item">Not recorded</span>;
    }
    const regular = Number(item.hours_worked || 0).toFixed(2);
    const overtime = Number(item.overtime_hours || 0).toFixed(2);
    const splitMatches = (Number(regular) + Number(overtime)).toFixed(2) === displayed.toFixed(2);
    const showSplit = splitMatches && item.employment_type !== 'salary'
      && !(item.employment_type === 'contractor' && displayed === 0);
    return <>{displayed.toFixed(2)}{showSplit && <p className="whitespace-normal text-xs text-neutral-600">{regular} reg + {overtime} OT</p>}</>;
  };
  const rowMenu = (item: PayrollItem): ReactNode => <details data-result-menu className="relative shrink-0" onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); event.currentTarget.removeAttribute('open'); event.currentTarget.querySelector('summary')?.focus(); } }}>
    <summary aria-label={`More actions for ${item.employee_name}`} className="inline-flex min-h-11 min-w-11 cursor-pointer list-none items-center justify-center rounded-full border border-neutral-200 text-neutral-700 [&::-webkit-details-marker]:hidden"><MoreHorizontal className="h-4 w-4" aria-hidden="true" /></summary>
    <div className="absolute right-0 z-30 flex w-48 flex-col gap-1 rounded-xl border border-neutral-200 bg-white p-2 shadow-lg" onClick={event => { if ((event.target as HTMLElement).closest('button,a')) { const menu = event.currentTarget.parentElement; menu?.removeAttribute('open'); menu?.querySelector('summary')?.focus(); } }}>
      <Link className="min-h-11 px-3 py-2 text-left text-sm text-primary-700" to={employeePath(companyId, item.employee_id, 'overview', { returnTo: currentPath })}>Employee profile</Link>
      {isCalculated && <Button variant="ghost" onClick={() => setEditingItem(item)}>Edit payroll</Button>}
      {isCommitted && item.employment_type !== 'contractor' && payPeriod.can_issue_corrective_paycheck && <Button variant="ghost" onClick={() => setCorrectingItem(item)}>Correct</Button>}
      {isCommitted && item.employment_type !== 'contractor' && payPeriod.cycle !== 'supplemental' && !item.voided && item.check_number && <Button variant="ghost" onClick={() => setReplacingItem(item)}>Replace check</Button>}
    </div>
  </details>;
  const flags = (item: PayrollItem) => [item.voided ? 'Voided' : '', item.correction_pay_basis_hold ? 'Pay setup held' : '', item.withholding_tax_override != null ? 'FIT override' : '', Number(item.withholding_tax_adjustment) ? 'FIT adjustment' : '', item.employment_type === 'contractor' ? '1099' : '', item.time_tracking_provenance ? 'Time tracking linked' : '', (item.wage_rate_hours || []).length > 1 ? 'Multiple rates' : '', Number(item.net_pay) < 0 ? 'Negative net' : ''].filter(Boolean).join(' · ') || '—';
  return <Card ref={root} className="min-w-0 overflow-visible">
    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-neutral-200 px-3 py-2 sm:px-4">
      <div className="flex flex-wrap items-center gap-3"><h3 className="font-semibold text-neutral-950">Employee payroll</h3>{props.primaryAction}</div>
      <div className="flex flex-wrap items-center gap-3">
        <Button variant="outline" size="sm" className="sm:hidden" onClick={() => setFiltersOpen(true)}>Filters</Button>
        <label className="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm text-neutral-700"><input type="checkbox" className="h-4 w-4 accent-primary-700" checked={showTaxDetail} onChange={event => { const value = event.target.checked; setShowTaxDetail(value); try { localStorage.setItem(preferenceKey, String(value)); } catch { /* Preference storage is optional. */ } }} />Show tax detail</label>
      </div>
    </div>
    <div className="hidden border-b border-neutral-200 p-3 sm:block">{filters}</div>
    <Dialog open={filtersOpen} onOpenChange={setFiltersOpen}><DialogContent className="max-w-lg"><DialogHeader><DialogTitle>Filters</DialogTitle></DialogHeader><div className="space-y-3">{filters}</div><Button onClick={() => setFiltersOpen(false)}>Show results</Button></DialogContent></Dialog>
    <div hidden={!showTaxDetail}>{fullDetail}</div>
    <div hidden={showTaxDetail}>
      <div className="hidden sm:block">
        <Table aria-label="Employee payroll results" containerClassName="h-[min(28rem,50vh)]" stickyHeader className="table-auto tabular-nums text-neutral-950 [&_th]:px-2 [&_td]:px-2 [&_td]:py-3">
          <TableHeader><TableRow><TableHead className="min-w-44">Employee</TableHead><TableHead className="min-w-20 text-right">Hours</TableHead><TableHead className="min-w-[7.5rem] whitespace-nowrap text-right">Gross</TableHead><TableHead className="min-w-[7.5rem] whitespace-nowrap text-right">Deductions</TableHead><TableHead className="min-w-[7.5rem] whitespace-nowrap text-right">Net</TableHead><TableHead className="min-w-28">Flags</TableHead><TableHead className="min-w-28">Details</TableHead></TableRow></TableHeader>
          <TableBody>{sortPayrollItems.map(item => <TableRow key={item.id} tabIndex={0} className="cursor-pointer focus-visible:outline-2 focus-visible:outline-primary-700" onClick={event => { if (!(event.target as HTMLElement).closest('button,a,details')) setReviewingItem(item); }} onKeyDown={event => { if (event.target === event.currentTarget && ['Enter', ' '].includes(event.key)) { event.preventDefault(); setReviewingItem(item); } }}>
            <TableCell className="whitespace-normal break-words"><p className="whitespace-normal break-words font-semibold">{item.employee_name}</p><p className="whitespace-normal break-words text-xs text-neutral-600">{item.department_name || item.employment_type}</p></TableCell>
            <TableCell className="text-right">{hours(item)}</TableCell>
            <TableCell className="whitespace-nowrap text-right">{money(item.gross_pay)}</TableCell><TableCell className="whitespace-nowrap text-right">{money(item.total_deductions)}</TableCell><TableCell className="whitespace-nowrap text-right font-semibold">{money(item.net_pay)}</TableCell><TableCell className="text-xs text-neutral-700"><p className="min-w-0 max-w-full whitespace-normal [overflow-wrap:anywhere]">{flags(item)}</p></TableCell>
            <TableCell><div className="flex min-w-0 items-center justify-end gap-1"><button type="button" aria-label="Details: open payroll item" className="min-h-11 shrink-0 text-sm font-semibold text-primary-700 underline" onClick={() => setReviewingItem(item)}>Details</button>{rowMenu(item)}</div></TableCell>
          </TableRow>)}</TableBody>
          <TableFooter><TableRow><TableCell>{sortPayrollItems.length === payrollItems.length ? 'Totals' : 'Filtered totals'} ({sortPayrollItems.length})</TableCell><TableCell className="text-right">{registerTotals.hours.toFixed(2)}</TableCell><TableCell className="whitespace-nowrap text-right">{money(registerTotals.gross)}</TableCell><TableCell className="whitespace-nowrap text-right">{money(registerTotals.deductions)}</TableCell><TableCell className="whitespace-nowrap text-right">{money(registerTotals.net)}</TableCell><TableCell colSpan={2} /></TableRow></TableFooter>
        </Table>
      </div>
      <div className="divide-y divide-neutral-200 sm:hidden" aria-label="Employee payroll results">
        {sortPayrollItems.map(item => <section key={item.id} aria-label={`Payroll result for ${item.employee_name}`} className="space-y-3 overflow-x-auto p-3">
          <div className="flex min-w-min items-start justify-between gap-3"><button className="min-h-11 min-w-0 break-words text-left font-semibold text-primary-800" onClick={() => setReviewingItem(item)}>{item.employee_name}<span className="block text-xs font-normal text-neutral-600">{item.department_name || item.employment_type}</span></button><div className="shrink-0 text-right"><p className="text-xs text-neutral-600">Net pay</p><p className="whitespace-nowrap text-lg font-semibold tabular-nums text-neutral-950">{money(item.net_pay)}</p></div></div>
          <dl className="grid grid-cols-[minmax(min-content,1fr)_minmax(max-content,1fr)_minmax(max-content,1fr)] gap-2 text-sm tabular-nums [&_dd]:whitespace-nowrap"><div><dt className="text-xs text-neutral-600">Hours</dt><dd>{hours(item)}</dd></div><div><dt className="text-xs text-neutral-600">Gross</dt><dd>{money(item.gross_pay)}</dd></div><div><dt className="text-xs text-neutral-600">Deductions</dt><dd>{money(item.total_deductions)}</dd></div></dl>
          <div className="flex items-center justify-between gap-2"><p className="min-w-0 flex-1 whitespace-normal text-xs text-neutral-700 [overflow-wrap:anywhere]">{flags(item)}</p><div className="flex shrink-0 items-center gap-2"><Button variant="outline" size="sm" onClick={() => setReviewingItem(item)}>View details</Button>{rowMenu(item)}</div></div>
        </section>)}
      </div>
      {sortPayrollItems.length === 0 && <p className="p-4 text-sm text-neutral-600">No employees match these filters.</p>}
    </div>
  </Card>;
}
