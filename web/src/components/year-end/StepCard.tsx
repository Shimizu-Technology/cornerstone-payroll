import { useState, type ReactElement, type ReactNode } from 'react';
import { CheckCircle2, ChevronDown, Circle, CircleAlert, FileDown, MinusCircle } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/utils';
import type { YearEndStep } from '@/lib/year-end';

const STATUS = {
  done: { label: 'Done', variant: 'success' as const, icon: CheckCircle2, tone: 'bg-success-50 text-success-800' },
  action_needed: { label: 'Needs action', variant: 'warning' as const, icon: CircleAlert, tone: 'bg-warning-50 text-warning-800' },
  waiting: { label: 'After step 1', variant: 'default' as const, icon: Circle, tone: 'bg-neutral-100 text-neutral-500' },
  not_needed: { label: 'Not needed', variant: 'default' as const, icon: MinusCircle, tone: 'bg-neutral-100 text-neutral-500' },
  available: { label: 'Downloads', variant: 'info' as const, icon: FileDown, tone: 'bg-primary-50 text-primary-800' },
};

interface StepCardProps {
  step: YearEndStep;
  isNext: boolean;
  /** Open on first render even when the step needs nothing. */
  defaultOpen?: boolean;
  children?: ReactNode;
}

/** One checklist step. Steps that need action open by default; finished ones collapse to a line. */
export function StepCard({ step, isNext, defaultOpen = false, children }: StepCardProps): ReactElement {
  const status = STATUS[step.status];
  const expandable = Boolean(children) && step.status !== 'waiting' && step.status !== 'not_needed';
  const [open, setOpen] = useState(step.status === 'action_needed' || isNext || defaultOpen);
  const Icon = status.icon;
  const headingId = `year-end-step-${step.key}`;

  return (
    <section
      id={`step-${step.key}`}
      aria-labelledby={headingId}
      className={cn(
        'scroll-mt-28 rounded-2xl border bg-white shadow-[0_14px_32px_-26px_rgba(15,23,42,0.55)]',
        isNext ? 'border-primary-300 ring-2 ring-primary-100' : 'border-neutral-200/80',
      )}
    >
      <div className="flex items-start gap-3 p-4 sm:p-5">
        <span className={cn('flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold', status.tone)} aria-hidden="true">
          {step.status === 'done' ? <Icon className="h-5 w-5" /> : step.number}
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h2 id={headingId} className="font-display text-base font-bold text-neutral-950 sm:text-lg">
              <span className="sr-only">Step {step.number}: </span>{step.title}
            </h2>
            <Badge variant={status.variant}>{status.label}</Badge>
            {isNext && <Badge variant="info">Next</Badge>}
          </div>
          <p className="mt-1 text-sm leading-6 text-neutral-600">{step.summary}</p>
        </div>
        {expandable && (
          <button
            type="button"
            onClick={() => setOpen((value) => !value)}
            aria-expanded={open}
            aria-controls={`${headingId}-body`}
            className="flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded-full text-neutral-600 hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300"
          >
            <ChevronDown className={cn('h-5 w-5 transition-transform', open && 'rotate-180')} aria-hidden="true" />
            <span className="sr-only">{open ? `Hide ${step.title}` : `Show ${step.title}`}</span>
          </button>
        )}
      </div>
      {expandable && open && (
        <div id={`${headingId}-body`} className="border-t border-neutral-200/70 px-4 pb-5 pt-4 sm:px-5">
          {children}
        </div>
      )}
    </section>
  );
}

export function IssueList({ issues }: { issues: YearEndStep['issues'] }): ReactElement | null {
  if (issues.length === 0) return null;
  return (
    <ul className="mb-4 space-y-1.5 text-sm text-neutral-800">
      {issues.map((issue, index) => (
        <li key={`${issue.code}-${issue.employee_id ?? issue.line ?? issue.warning_code ?? index}`} className="flex gap-2">
          <CircleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
          <span className="min-w-0 [overflow-wrap:anywhere]">{issue.message}</span>
        </li>
      ))}
    </ul>
  );
}
