import { Fragment, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { AlertTriangle, CheckCircle2, Info, Loader2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import type { PayrollRegisterReport } from '@/services/api';
import { ReportDownloadMenu, type ReportDownloadFormat } from './ReportDownloadMenu';

type PayrollRegister = PayrollRegisterReport['report'];
type SimpleRegister = NonNullable<PayrollRegister['simple_register']>;
type SimpleColumn = SimpleRegister['columns'][number];
type PayrollWorker = PayrollRegister['employees'][number];
type PayrollFieldEntry = NonNullable<PayrollWorker['payroll_field_entries']>[number];

type PayrollFieldGroup = 'addition' | 'deduction' | 'employer';

interface PayrollFieldColumn {
  key: string;
  label: string;
  treatment: string;
  group: PayrollFieldGroup;
  kind: string;
  taxTreatment: string;
  employeePaid: boolean;
  employerPaid: boolean;
}

function currency(value: unknown) {
  const amount = Number(value ?? 0);
  return amount.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

function decimal(value: unknown) {
  const amount = Number(value ?? 0);
  return amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function simpleValue(column: SimpleColumn, value: string | number | null) {
  if (value === null || value === undefined || value === '') return '';
  if (column.format === 'currency') return currency(value);
  if (column.format === 'number') return decimal(value);
  return String(value);
}

function simpleCellClass(column: SimpleColumn, header = false) {
  const numeric = column.format === 'currency' || column.format === 'number' || column.format === 'count';
  const calculated = column.calculated ? 'bg-blue-50/90' : header ? 'bg-slate-50' : 'bg-white';
  const sticky = column.key === 'count'
    ? `sticky left-0 z-20 ${header ? 'bg-slate-50' : calculated}`
    : column.key === 'employee'
      ? `sticky left-12 z-20 ${header ? 'bg-slate-50' : calculated}`
      : calculated;
  return `${sticky} ${numeric ? 'text-right tabular-nums' : 'text-left'}`;
}

const payrollFieldTreatmentLabels: Record<string, string> = {
  taxable_addition: 'Taxable addition',
  non_taxable_addition: 'Non-taxable addition',
  pre_tax_deduction: 'Pre-tax deduction',
  post_tax_deduction: 'Post-tax deduction',
  employer_contribution: 'Employer contribution',
};

const payrollFieldSourceLabels: Record<string, string> = {
  employee_default: 'Employee default',
  manual: 'Payroll override',
  import: 'Imported',
  system: 'System',
};

function payrollFieldGroup(entry: PayrollFieldEntry): PayrollFieldGroup {
  if (entry.tax_treatment === 'employer_contribution' || (entry.employer_paid && !entry.employee_paid)) return 'employer';
  if (entry.kind === 'deduction' || ['pre_tax_deduction', 'post_tax_deduction'].includes(entry.tax_treatment)) return 'deduction';
  return 'addition';
}

function payrollFieldIdentity(entry: PayrollFieldEntry) {
  return [
    entry.label,
    entry.kind,
    entry.tax_treatment,
    entry.employee_paid ? 'employee' : '',
    entry.employer_paid ? 'employer' : '',
  ].join(':');
}

function payrollFieldColumns(workers: PayrollWorker[]): PayrollFieldColumn[] {
  const columns = new Map<string, PayrollFieldColumn>();
  workers.forEach((worker) => {
    (worker.payroll_field_entries || []).filter((entry) => entry.active !== false).forEach((entry) => {
      const key = payrollFieldIdentity(entry);
      if (columns.has(key)) return;
      columns.set(key, {
        key,
        label: entry.label,
        treatment: payrollFieldTreatmentLabels[entry.tax_treatment] || entry.tax_treatment,
        group: payrollFieldGroup(entry),
        kind: entry.kind,
        taxTreatment: entry.tax_treatment,
        employeePaid: Boolean(entry.employee_paid),
        employerPaid: Boolean(entry.employer_paid),
      });
    });
  });

  const groupOrder: Record<PayrollFieldGroup, number> = { addition: 0, deduction: 1, employer: 2 };
  return Array.from(columns.values()).sort((a, b) => (
    groupOrder[a.group] - groupOrder[b.group]
      || a.treatment.localeCompare(b.treatment)
      || a.label.localeCompare(b.label)
  ));
}

function payrollFieldAmount(worker: PayrollWorker, column: PayrollFieldColumn): number | null {
  const matching = (worker.payroll_field_entries || []).filter((entry) => (
    entry.active !== false && payrollFieldIdentity(entry) === column.key
  ));
  if (matching.length === 0) return null;
  return matching.reduce((total, entry) => total + Number(entry.amount || 0), 0);
}

function payrollFieldHeaderClass(group: PayrollFieldGroup) {
  if (group === 'addition') return 'bg-emerald-50 text-emerald-950';
  if (group === 'deduction') return 'bg-amber-50 text-amber-950';
  return 'bg-indigo-50 text-indigo-950';
}

function PayrollFieldHeader({ column }: { column: PayrollFieldColumn }) {
  const inclusion = column.group === 'addition'
    ? 'Included in gross'
    : column.group === 'deduction'
      ? 'Included in deductions'
      : 'Employer only';
  return (
    <th className={`${payrollFieldHeaderClass(column.group)} min-w-36 border-b border-r border-slate-200 px-3 py-2 align-bottom`}>
      <span className="block font-bold leading-4">{column.label}</span>
      <span className="mt-1 block text-[10px] font-medium leading-3 opacity-70">{column.treatment} · {inclusion}</span>
    </th>
  );
}

function PayrollFieldCell({ worker, column }: { worker: PayrollWorker; column: PayrollFieldColumn }) {
  const amount = payrollFieldAmount(worker, column);
  return (
    <td className="border-b border-r border-slate-100 bg-white px-3 py-2 text-right tabular-nums">
      {amount === null ? <span className="text-slate-400">—</span> : currency(amount)}
    </td>
  );
}

function SimpleRegisterPreview({ report, simple }: { report: PayrollRegister; simple: SimpleRegister }) {
  const reviewCount = simple.review.filter((row) => row.severity === 'Review').length;
  const infoCount = simple.review.filter((row) => row.severity === 'Info').length;

  return (
    <div className="space-y-5">
      <section className="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm">
        <div className="bg-[#1f4e78] px-5 py-4 text-white">
          <p className="text-xs font-bold uppercase tracking-[0.16em] text-blue-100">Payroll register</p>
          <div className="mt-1 flex flex-wrap items-end justify-between gap-3">
            <div>
              <h2 className="text-xl font-bold tracking-tight">{report.meta.company_name || 'Payroll client'}</h2>
              <p className="mt-1 text-sm text-blue-100">
                {report.pay_period.start_date} – {report.pay_period.end_date} · Pay date {report.pay_period.pay_date}
              </p>
            </div>
            <span className="rounded-full bg-white/15 px-3 py-1 text-xs font-semibold uppercase tracking-wide">
              {report.pay_period.status}
            </span>
          </div>
        </div>

        <div className="space-y-4 p-5">
          <p className="rounded-xl border border-blue-100 bg-blue-50 px-4 py-3 text-sm italic leading-6 text-blue-900">
            {simple.note}
          </p>
          <div>
            <h3 className="text-sm font-bold uppercase tracking-[0.12em] text-neutral-500">Pay period information</h3>
            <dl className="mt-3 grid gap-x-8 gap-y-3 sm:grid-cols-2 xl:grid-cols-4">
              {simple.pay_period_information.map((row) => (
                <div key={row.label} className="min-w-0">
                  <dt className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{row.label}</dt>
                  <dd className="mt-1 break-words text-sm font-medium text-neutral-900">{row.value || 'Not recorded'}</dd>
                </div>
              ))}
            </dl>
          </div>
        </div>
      </section>

      <section className="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-neutral-200 px-5 py-4">
          <div>
            <h3 className="font-bold text-neutral-950">Employee register</h3>
            <p className="mt-0.5 text-sm text-neutral-500">{simple.rows.length} employees · values match the downloadable Excel register</p>
          </div>
          <div className="flex items-center gap-2 text-xs font-semibold">
            {reviewCount === 0 ? (
              <span className="rounded-full bg-emerald-100 px-3 py-1 text-emerald-800">No review exceptions</span>
            ) : (
              <span className="rounded-full bg-amber-100 px-3 py-1 text-amber-900">{reviewCount} review item{reviewCount === 1 ? '' : 's'}</span>
            )}
            {infoCount > 0 && <span className="rounded-full bg-blue-100 px-3 py-1 text-blue-800">{infoCount} info</span>}
          </div>
        </div>

        <div className="max-h-[58vh] overflow-auto">
          <table className="min-w-[2100px] border-separate border-spacing-0 text-xs">
            <thead className="sticky top-0 z-30">
              <tr>
                {simple.columns.map((column) => (
                  <th
                    key={`hint-${column.key}`}
                    className={`${simpleCellClass(column, true)} min-w-12 border-b border-r border-blue-100 px-2.5 py-2 align-bottom text-[10px] font-medium italic leading-4 text-slate-500`}
                    title={column.hint || undefined}
                  >
                    {column.hint}
                  </th>
                ))}
              </tr>
              <tr>
                {simple.columns.map((column) => (
                  <th
                    key={column.key}
                    className={`${simpleCellClass(column, true)} border-b-2 border-r border-slate-200 px-2.5 py-2.5 font-bold text-slate-900`}
                  >
                    {column.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {simple.rows.map((row, rowIndex) => (
                <tr key={`${String(row.employee)}-${rowIndex}`} className="group hover:bg-blue-50/40">
                  {simple.columns.map((column) => (
                    <td
                      key={column.key}
                      className={`${simpleCellClass(column)} border-b border-r border-slate-100 px-2.5 py-2 text-slate-800 group-hover:bg-blue-50/70 ${column.key === 'employee' ? 'min-w-56 font-semibold' : ''}`}
                    >
                      {simpleValue(column, row[column.key])}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
            <tfoot className="sticky bottom-0 z-20">
              <tr>
                {simple.columns.map((column) => (
                  <td
                    key={column.key}
                    className={`${simpleCellClass(column)} border-t-2 border-r border-[#7f9db9] bg-[#eaf2f8] px-2.5 py-2.5 font-bold text-slate-950`}
                  >
                    {simpleValue(column, simple.total[column.key])}
                  </td>
                ))}
              </tr>
            </tfoot>
          </table>
        </div>
      </section>

      {report.contractors.length > 0 && (
        <section className="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm">
          <div className="border-b border-neutral-200 px-5 py-4">
            <h3 className="font-bold text-neutral-950">1099 contractor detail</h3>
            <p className="mt-0.5 text-sm text-neutral-500">
              Informational contractor payments are shown separately and are not included in the simplified W-2 totals.
            </p>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full text-sm">
              <thead className="bg-slate-100 text-left text-xs uppercase tracking-wide text-slate-600">
                <tr>
                  <th className="border-b border-r border-slate-200 px-4 py-2.5">Contractor</th>
                  <th className="border-b border-r border-slate-200 px-4 py-2.5">Type</th>
                  <th className="border-b border-r border-slate-200 px-4 py-2.5 text-right">Gross pay</th>
                  <th className="border-b border-r border-slate-200 px-4 py-2.5 text-right">Net pay</th>
                  <th className="border-b border-slate-200 px-4 py-2.5">Check #</th>
                </tr>
              </thead>
              <tbody>
                {report.contractors.map((contractor) => (
                  <tr key={contractor.employee_id} className="hover:bg-blue-50/50">
                    <td className="border-b border-r border-slate-100 px-4 py-2.5 font-semibold">{contractor.employee_name}</td>
                    <td className="border-b border-r border-slate-100 px-4 py-2.5 capitalize">{contractor.employment_type}</td>
                    <td className="border-b border-r border-slate-100 px-4 py-2.5 text-right tabular-nums">{currency(contractor.gross_pay)}</td>
                    <td className="border-b border-r border-slate-100 px-4 py-2.5 text-right font-semibold tabular-nums">{currency(contractor.net_pay)}</td>
                    <td className="border-b border-slate-100 px-4 py-2.5 font-mono">{contractor.check_number || ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 className="font-bold text-neutral-950">Register review</h3>
            <p className="mt-0.5 text-sm text-neutral-500">Exceptions and informational items that do not fit the simplified columns.</p>
          </div>
        </div>
        <div className="mt-4 space-y-2.5">
          {simple.review.map((row, index) => {
            const tone = row.severity === 'OK'
              ? 'border-emerald-200 bg-emerald-50 text-emerald-950'
              : row.severity === 'Info'
                ? 'border-blue-200 bg-blue-50 text-blue-950'
                : 'border-amber-200 bg-amber-50 text-amber-950';
            const Icon = row.severity === 'OK' ? CheckCircle2 : row.severity === 'Info' ? Info : AlertTriangle;
            return (
              <div key={`${row.issue}-${row.employee || index}`} className={`flex gap-3 rounded-xl border p-3.5 ${tone}`}>
                <Icon className="mt-0.5 h-5 w-5 shrink-0" />
                <div>
                  <p className="text-sm font-bold">{row.issue}</p>
                  {row.employee && <p className="mt-0.5 text-xs font-semibold opacity-80">{row.employee}</p>}
                  {row.detail && <p className="mt-1 text-sm leading-5 opacity-85">{row.detail}</p>}
                </div>
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function DetailedRegisterPreview({ report }: { report: PayrollRegister }) {
  const workers = [...report.employees, ...report.contractors];
  const fieldColumns = payrollFieldColumns(workers);
  const additionColumns = fieldColumns.filter((column) => column.group === 'addition');
  const deductionColumns = fieldColumns.filter((column) => column.group === 'deduction');
  const employerColumns = fieldColumns.filter((column) => column.group === 'employer');
  const columnCount = 14 + fieldColumns.length;
  const total = (key: keyof PayrollWorker) => workers.reduce((sum, worker) => sum + Number(worker[key] || 0), 0);
  const fieldTotal = (column: PayrollFieldColumn) => workers.reduce((sum, worker) => (
    sum + (payrollFieldAmount(worker, column) || 0)
  ), 0);
  const contractorCount = report.summary.contractor_count ?? report.contractors.length;
  const contractorGross = report.summary.contractor_total_gross
    ?? report.contractors.reduce((total, contractor) => total + Number(contractor.gross_pay ?? 0), 0);
  const contractorNet = report.summary.contractor_total_net
    ?? report.contractors.reduce((total, contractor) => total + Number(contractor.net_pay ?? 0), 0);
  const summaryItems = [
    ['Workers', (report.summary.employee_count + contractorCount).toLocaleString()],
    ['W-2 gross', currency(report.summary.total_gross)],
    ['1099 gross', currency(contractorGross)],
    ['Withholding', currency(report.summary.total_withholding)],
    ['Deductions', currency(report.summary.total_deductions)],
    ['Total net', currency(Number(report.summary.total_net) + Number(contractorNet))],
  ];
  const workerSections = [
    { label: 'W-2 employees', workers: report.employees },
    { label: '1099 contractors', workers: report.contractors },
  ].filter((section) => section.workers.length > 0);

  return (
    <div className="space-y-5">
      <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
        <p className="text-xs font-bold uppercase tracking-[0.16em] text-primary-700">Detailed payroll register</p>
        <h2 className="mt-1 text-xl font-bold text-neutral-950">{report.meta.company_name || 'Payroll client'}</h2>
        <p className="mt-1 text-sm text-neutral-500">
          {report.pay_period.start_date} – {report.pay_period.end_date} · Pay date {report.pay_period.pay_date}
        </p>
        <div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
          {summaryItems.map(([label, value]) => (
            <div key={label} className="rounded-xl border border-neutral-200 bg-neutral-50 px-4 py-3">
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p>
              <p className="mt-1 text-lg font-bold text-neutral-950">{value}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm">
        <div className="flex flex-wrap items-end justify-between gap-3 border-b border-neutral-200 px-5 py-4">
          <h3 className="font-bold text-neutral-950">Payroll worker detail</h3>
          {fieldColumns.length > 0 && (
            <p className="max-w-2xl text-xs leading-5 text-neutral-500">
              Named payroll fields appear beside the totals they affect. A dash means the field was not assigned; $0.00 means it was assigned with no amount this payroll.
            </p>
          )}
        </div>
        <div className="max-h-[60vh] overflow-auto">
          <table className="text-xs" style={{ minWidth: `${1450 + (fieldColumns.length * 144)}px` }}>
            <thead className="sticky top-0 z-10 bg-slate-100 text-left text-slate-700">
              <tr>
                <th className="sticky left-0 z-20 min-w-52 border-b border-r border-slate-200 bg-slate-100 px-3 py-2.5 font-bold">Employee</th>
                {['Type', 'Hours', 'OT Hours', 'Reported Tips', 'Tips Out'].map((label) => (
                  <th key={label} className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">{label}</th>
                ))}
                {additionColumns.map((column) => <PayrollFieldHeader key={column.key} column={column} />)}
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Gross Pay</th>
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Withholding</th>
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Add&apos;l W/H</th>
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Social Security</th>
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Medicare</th>
                {deductionColumns.map((column) => <PayrollFieldHeader key={column.key} column={column} />)}
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Deductions</th>
                <th className="border-b border-r border-slate-200 px-3 py-2.5 font-bold">Net Pay</th>
                {employerColumns.map((column) => <PayrollFieldHeader key={column.key} column={column} />)}
                <th className="border-b border-slate-200 px-3 py-2.5 font-bold">Check #</th>
              </tr>
            </thead>
            <tbody>
              {workerSections.map((section) => (
                <Fragment key={section.label}>
                  <tr className="bg-slate-50">
                    <td colSpan={columnCount} className="border-b border-slate-200 px-3 py-2 text-xs font-bold uppercase tracking-wide text-slate-600">
                      {section.label} · {section.workers.length}
                    </td>
                  </tr>
                  {section.workers.map((worker) => (
                    <tr key={worker.employee_id} className="group hover:bg-blue-50/50">
                      <td className="sticky left-0 z-[1] border-b border-r border-slate-100 bg-white px-3 py-2 font-semibold group-hover:bg-blue-50">{worker.employee_name}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 capitalize">{worker.employment_type}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{decimal(worker.hours_worked)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{decimal(worker.overtime_hours)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.reported_tips)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.tips_paid_out)}</td>
                      {additionColumns.map((column) => <PayrollFieldCell key={column.key} worker={worker} column={column} />)}
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.gross_pay)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.withholding_tax)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.additional_withholding)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.social_security_tax)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.medicare_tax)}</td>
                      {deductionColumns.map((column) => <PayrollFieldCell key={column.key} worker={worker} column={column} />)}
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right tabular-nums">{currency(worker.total_deductions)}</td>
                      <td className="border-b border-r border-slate-100 px-3 py-2 text-right font-bold tabular-nums">{currency(worker.net_pay)}</td>
                      {employerColumns.map((column) => <PayrollFieldCell key={column.key} worker={worker} column={column} />)}
                      <td className="border-b border-slate-100 px-3 py-2 font-mono">{worker.check_number || ''}</td>
                    </tr>
                  ))}
                </Fragment>
              ))}
            </tbody>
            <tfoot className="sticky bottom-0 z-10 bg-slate-100 text-slate-950">
              <tr>
                <td className="sticky left-0 z-20 border-t-2 border-r border-slate-300 bg-slate-100 px-3 py-2.5 font-bold">TOTALS</td>
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5" />
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{decimal(total('hours_worked'))}</td>
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{decimal(total('overtime_hours'))}</td>
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(total('reported_tips'))}</td>
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(total('tips_paid_out'))}</td>
                {additionColumns.map((column) => (
                  <td key={column.key} className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(fieldTotal(column))}</td>
                ))}
                {(['gross_pay', 'withholding_tax', 'additional_withholding', 'social_security_tax', 'medicare_tax'] as Array<keyof PayrollWorker>).map((key) => (
                  <td key={key} className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(total(key))}</td>
                ))}
                {deductionColumns.map((column) => (
                  <td key={column.key} className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(fieldTotal(column))}</td>
                ))}
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(total('total_deductions'))}</td>
                <td className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(total('net_pay'))}</td>
                {employerColumns.map((column) => (
                  <td key={column.key} className="border-t-2 border-r border-slate-300 px-3 py-2.5 text-right font-bold tabular-nums">{currency(fieldTotal(column))}</td>
                ))}
                <td className="border-t-2 border-slate-300 px-3 py-2.5" />
              </tr>
            </tfoot>
          </table>
        </div>
      </section>
    </div>
  );
}

function PayrollFieldsDisclosure({ report }: { report: PayrollRegister }) {
  const workers = [...report.employees, ...report.contractors];
  const rows = workers.flatMap((worker) => (
    (worker.payroll_field_entries || [])
      .filter((entry) => entry.active !== false)
      .map((entry) => ({
        worker: worker.employee_name,
        label: entry.label,
        treatment: payrollFieldTreatmentLabels[entry.tax_treatment] || entry.tax_treatment,
        source: payrollFieldSourceLabels[entry.source || ''] || entry.source || 'Calculated',
        effect: entry.employer_paid && !entry.employee_paid
          ? 'Employer expense'
          : entry.kind === 'deduction'
            ? 'Employee deduction'
            : 'Employee earnings',
        amount: Number(entry.amount || 0),
      }))
  ));

  if (rows.length === 0) return null;

  const totals = Array.from(rows.reduce((summary, row) => {
    const key = `${row.label}:${row.treatment}:${row.effect}`;
    const existing = summary.get(key);
    summary.set(key, existing
      ? { ...existing, amount: existing.amount + row.amount }
      : { label: row.label, treatment: row.treatment, effect: row.effect, amount: row.amount });
    return summary;
  }, new Map<string, { label: string; treatment: string; effect: string; amount: number }>()).values());

  return (
    <section className="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm">
      <div className="border-b border-neutral-200 px-5 py-4">
        <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Company payroll fields</p>
        <h3 className="mt-1 font-bold text-neutral-950">Additions, deductions, and employer benefits</h3>
        <p className="mt-1 max-w-4xl text-sm leading-6 text-neutral-600">
          These snapshotted values are already reflected in gross pay, deductions, net pay, and taxable wages according to each field&apos;s treatment. This section keeps every client-wide field visible for review and reconciliation.
        </p>
      </div>

      <div className="grid gap-3 border-b border-neutral-200 bg-neutral-50/70 p-4 sm:grid-cols-2 xl:grid-cols-4">
        {totals.map((total) => (
          <div key={`${total.label}:${total.treatment}:${total.effect}`} className="rounded-xl border border-neutral-200 bg-white px-4 py-3 shadow-sm">
            <p className="truncate text-sm font-bold text-neutral-950" title={total.label}>{total.label}</p>
            <p className="mt-1 text-xs text-neutral-500">{total.treatment} · {total.effect}</p>
            <p className="mt-2 text-lg font-bold tabular-nums text-neutral-950">{currency(total.amount)}</p>
          </div>
        ))}
      </div>

      <div className="max-h-[45vh] overflow-auto">
        <table className="min-w-[920px] w-full text-sm">
          <thead className="sticky top-0 z-10 bg-slate-100 text-left text-xs uppercase tracking-wide text-slate-600">
            <tr>
              <th className="border-b border-r border-slate-200 px-4 py-2.5">Worker</th>
              <th className="border-b border-r border-slate-200 px-4 py-2.5">Payroll field</th>
              <th className="border-b border-r border-slate-200 px-4 py-2.5">Treatment</th>
              <th className="border-b border-r border-slate-200 px-4 py-2.5">Payroll effect</th>
              <th className="border-b border-r border-slate-200 px-4 py-2.5">Source</th>
              <th className="border-b border-slate-200 px-4 py-2.5 text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row, index) => (
              <tr key={`${row.worker}:${row.label}:${index}`} className="hover:bg-blue-50/50">
                <td className="border-b border-r border-slate-100 px-4 py-2.5 font-semibold text-neutral-950">{row.worker}</td>
                <td className="border-b border-r border-slate-100 px-4 py-2.5">{row.label}</td>
                <td className="border-b border-r border-slate-100 px-4 py-2.5">{row.treatment}</td>
                <td className="border-b border-r border-slate-100 px-4 py-2.5">{row.effect}</td>
                <td className="border-b border-r border-slate-100 px-4 py-2.5">{row.source}</td>
                <td className="border-b border-slate-100 px-4 py-2.5 text-right font-bold tabular-nums">{currency(row.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export function PayrollRegisterPreviewContent({ report }: { report: PayrollRegister }) {
  const register = report.simple_payroll_register_enabled && report.simple_register
    ? <SimpleRegisterPreview report={report} simple={report.simple_register} />
    : <DetailedRegisterPreview report={report} />;

  return (
    <div className="space-y-5">
      {register}
      <PayrollFieldsDisclosure report={report} />
    </div>
  );
}

interface PayrollRegisterPreviewModalProps {
  open: boolean;
  loading: boolean;
  report: PayrollRegister | null;
  error: string | null;
  onClose: () => void;
  downloadFormats: ReportDownloadFormat[];
}

export function PayrollRegisterPreviewModal({
  open,
  loading,
  report,
  error,
  onClose,
  downloadFormats,
}: PayrollRegisterPreviewModalProps) {
  useEffect(() => {
    if (!open) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [open, onClose]);

  if (!open || typeof document === 'undefined') return null;

  return createPortal(
    <div className="fixed inset-0 z-[110] flex flex-col bg-neutral-950/70 backdrop-blur-sm" role="dialog" aria-modal="true" aria-label="Payroll Register preview">
      <div className="m-2 flex min-h-0 flex-1 flex-col overflow-hidden rounded-2xl bg-neutral-100 shadow-2xl sm:m-5">
        <header className="flex shrink-0 items-center justify-between gap-4 border-b border-neutral-800 bg-neutral-950 px-4 py-3 text-white sm:px-5">
          <div className="min-w-0">
            <p className="truncate text-sm font-bold sm:text-base">Payroll Register</p>
            <p className="truncate text-xs text-neutral-400">
              {report ? `${report.pay_period.start_date} – ${report.pay_period.end_date}` : 'Loading report preview'}
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <ReportDownloadMenu formats={downloadFormats} disabled={loading || !report} />
            <Button type="button" variant="ghost" size="sm" onClick={onClose} className="px-2 text-white hover:bg-white/10 hover:text-white" aria-label="Close payroll register preview">
              <X className="h-4 w-4" />
            </Button>
          </div>
        </header>

        <main className="min-h-0 flex-1 overflow-y-auto p-3 sm:p-5">
          {loading && (
            <div className="flex min-h-[420px] items-center justify-center">
              <div className="flex items-center gap-3 rounded-full border border-neutral-200 bg-white px-5 py-3 text-sm font-semibold text-neutral-600 shadow-sm">
                <Loader2 className="h-4 w-4 animate-spin text-primary-700" />
                Preparing payroll register
              </div>
            </div>
          )}
          {!loading && error && (
            <div className="mx-auto max-w-xl rounded-2xl border border-red-200 bg-red-50 p-5 text-sm text-red-800">
              <p className="font-bold">Unable to load the payroll register</p>
              <p className="mt-1">{error}</p>
            </div>
          )}
          {!loading && !error && report && <PayrollRegisterPreviewContent report={report} />}
        </main>
      </div>
    </div>,
    document.body
  );
}
