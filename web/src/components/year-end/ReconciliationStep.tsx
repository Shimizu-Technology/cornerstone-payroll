import { useState, type ReactElement } from 'react';
import { Link } from 'react-router';
import { Check } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency, formatDate } from '@/lib/utils';
import type { YearEndReconciliationLine, YearEndStep } from '@/lib/year-end';

type ReconciliationStepData = Extract<YearEndStep, { key: 'reconciliation' }>;

function LineStatus({ line }: { line: YearEndReconciliationLine }): ReactElement {
  if (line.status === 'match') return <Badge variant="success">Matches</Badge>;
  if (line.status === 'explained') return <Badge variant="info">Matches in total</Badge>;
  return <Badge variant="danger">Off by {formatCurrency(Math.abs(line.difference))}</Badge>;
}

function LineNote({ line }: { line: YearEndReconciliationLine }): ReactElement | null {
  if (!line.note) return null;
  return <p className="mt-2 text-sm text-neutral-700">{line.note}</p>;
}

function LookAt({ line }: { line: YearEndReconciliationLine }): ReactElement | null {
  if (line.status !== 'mismatch' || line.look_at.length === 0) return null;
  return (
    <ul className="mt-2 space-y-1 text-sm text-danger-800">
      {line.look_at.map((target) => (
        <li key={target.label}>
          <span className="font-semibold">{target.label}:</span> {target.detail}{' '}
          <Link to={target.kind === 'quarter' ? '/reports?report=941-gu' : '/reports?report=w2-gu'} className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline xl:min-h-0">
            Open {target.kind === 'quarter' ? 'Form 941' : 'W-2GU report'}
          </Link>
        </li>
      ))}
    </ul>
  );
}

function MobileLine({ line, openingPresent }: { line: YearEndReconciliationLine; openingPresent: boolean }): ReactElement {
  const [open, setOpen] = useState(line.status === 'mismatch');
  const returns = line.source === 'w1' ? 'W-1s' : '941s';
  return (
    <li className="rounded-xl border border-neutral-200 p-3">
      <div className="flex items-start justify-between gap-2">
        <p className="min-w-0 text-sm font-semibold text-neutral-950">{line.label} <span className="font-normal text-neutral-500">({line.w2_box})</span></p>
        <LineStatus line={line} />
      </div>
      <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
        <dt className="text-neutral-600">W-2s</dt><dd className="text-right tabular-nums">{formatCurrency(line.w2_total)}</dd>
        <dt className="text-neutral-600">{returns}</dt><dd className="text-right tabular-nums">{formatCurrency(line.quarterly_total)}</dd>
        {openingPresent && (<><dt className="text-neutral-600">Opening balances</dt><dd className="text-right tabular-nums">{formatCurrency(line.opening_balances)}</dd></>)}
        <dt className="font-semibold text-neutral-800">Difference</dt><dd className="text-right font-semibold tabular-nums">{formatCurrency(line.difference)}</dd>
      </dl>
      <button type="button" onClick={() => setOpen((value) => !value)} aria-expanded={open} className="mt-2 min-h-11 text-sm font-semibold text-primary-700 underline">
        {open ? 'Hide quarters' : 'Show quarters'}
      </button>
      {open && (
        <dl className="mt-1 grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
          {line.quarters.map((quarter) => (
            <div key={quarter.quarter} className="contents">
              <dt className="text-neutral-600">Q{quarter.quarter} {line.source === 'w1' ? 'W-1' : '941'}</dt>
              <dd className="text-right tabular-nums">{formatCurrency(quarter.amount)}</dd>
            </div>
          ))}
        </dl>
      )}
      <LineNote line={line} />
      <LookAt line={line} />
    </li>
  );
}

export function ReconciliationStep({ step }: { step: ReconciliationStepData }): ReactElement {
  const data = step.data;
  const lines = data.lines ?? [];
  const opening = data.opening_balances;
  const openingPresent = Boolean(opening?.present);
  const externalQuarters = (data.quarters ?? []).filter((quarter) => quarter.form_941_filed_by === 'external_provider');
  const withholdingProblems = (data.form_941_reviews ?? []).filter((review) => review.status === 'unexplained');

  if (data.status === 'unavailable') {
    return <p className="text-sm text-danger-700">{step.issues[0]?.message ?? data.error}</p>;
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-neutral-700">
        Each W-2 total should equal the four quarterly returns{openingPresent ? ' plus opening balances' : ''}. Differences over one cent block marking the W-2s ready.
      </p>
      {openingPresent && (
        <p className="rounded-xl border border-primary-100 bg-primary-50/60 p-3 text-sm text-neutral-800">
          Opening balances cover pay dates {opening?.first_pay_date ? formatDate(opening.first_pay_date) : ''} to {opening?.last_pay_date ? formatDate(opening.last_pay_date) : ''}. They are in the W-2s but not in this app's 941s and W-1s, so they are shown in their own column.
        </p>
      )}
      {withholdingProblems.length > 0 && (
        <ul className="space-y-1.5 rounded-xl border border-danger-200 bg-danger-50/50 p-3 text-sm text-danger-800" aria-label="941 withholding problems">
          {withholdingProblems.map((review) => (
            <li key={review.quarter}>
              {review.message}{' '}
              <Link to="/reports?report=941-gu" className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline xl:min-h-0">Open Form 941</Link>
            </li>
          ))}
        </ul>
      )}
      {externalQuarters.length > 0 && (
        <p className="text-sm text-neutral-700">
          {externalQuarters.map((quarter) => quarter.label).join(', ')} 941 {externalQuarters.length === 1 ? 'was' : 'were'} filed by the prior provider. The amounts shown are rebuilt from the imported history.
        </p>
      )}

      <ul className="space-y-3 xl:hidden">
        {lines.map((line) => <MobileLine key={line.key} line={line} openingPresent={openingPresent} />)}
      </ul>

      <div className="hidden xl:block">
        <Table className="[&_td]:px-3 [&_th]:px-3">
          <TableHeader>
            <TableRow>
              <TableHead>Line</TableHead>
              <TableHead className="text-right">W-2s</TableHead>
              {[1, 2, 3, 4].map((quarter) => <TableHead key={quarter} className="text-right">Q{quarter}</TableHead>)}
              {openingPresent && <TableHead className="text-right">Opening</TableHead>}
              <TableHead className="text-right">Difference</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.map((line) => (
              <TableRow key={line.key} className={line.status === 'mismatch' ? 'bg-danger-50/40' : undefined}>
                <TableCell className="min-w-[13rem] whitespace-normal">
                  <p className="font-medium text-neutral-950">{line.label} <span className="text-neutral-500">({line.w2_box})</span></p>
                  <p className="text-xs text-neutral-600">vs {line.source_label}</p>
                  <LineNote line={line} />
                  <LookAt line={line} />
                </TableCell>
                <TableCell className="text-right tabular-nums">{formatCurrency(line.w2_total)}</TableCell>
                {line.quarters.map((quarter) => (
                  <TableCell key={quarter.quarter} className={`text-right tabular-nums ${Math.abs(quarter.difference) > 0.01 ? 'font-semibold text-danger-700' : ''}`}>
                    {formatCurrency(quarter.amount)}
                  </TableCell>
                ))}
                {openingPresent && <TableCell className="text-right tabular-nums">{formatCurrency(line.opening_balances)}</TableCell>}
                <TableCell className="text-right">
                  <span className={`inline-flex items-center gap-1 font-semibold tabular-nums ${line.status === 'match' ? 'text-success-800' : line.status === 'explained' ? 'text-neutral-800' : 'text-danger-700'}`}>
                    {line.status === 'match' && <Check className="h-4 w-4" aria-hidden="true" />}
                    {formatCurrency(line.difference)}
                  </span>
                  <span className="sr-only">{line.status === 'match' ? 'Matches' : line.status === 'explained' ? 'Matches in total with the other Social Security line' : 'Does not match'}</span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
