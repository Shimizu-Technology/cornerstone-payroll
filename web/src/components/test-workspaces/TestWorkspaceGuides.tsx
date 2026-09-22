import type { ReactElement } from 'react';
import { ChevronDown, DatabaseBackup, FlaskConical, GraduationCap, ShieldCheck } from 'lucide-react';

import { Badge } from '@/components/ui/badge';

export function TestWorkspaceGuide(): ReactElement {
  return (
    <details className="group rounded-[1.35rem] border border-neutral-200/80 bg-white shadow-sm">
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 rounded-[1.35rem] px-4 py-4 marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 sm:px-6">
        <div>
          <p className="text-sm font-semibold text-neutral-950">Test workspace guide</p>
          <p className="mt-2 text-xs leading-5 text-neutral-600">Understand environments, statuses, and access before you start.</p>
        </div>
        <ChevronDown aria-hidden="true" className="h-5 w-5 shrink-0 text-neutral-500 transition-transform group-open:rotate-180" />
      </summary>
      <div className="grid gap-6 border-t border-neutral-200 px-4 py-4 sm:px-6 lg:grid-cols-2">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">Environment types</p>
          <dl className="mt-4 space-y-4 text-sm">
            <div className="flex gap-2"><ShieldCheck aria-hidden="true" className="h-4 w-4 shrink-0 text-primary-700" /><div><dt className="font-semibold text-neutral-900">Production client</dt><dd className="mt-2 leading-5 text-neutral-600">The live payroll record. Normal approvals, commits, payments, and reporting happen here.</dd></div></div>
            <div className="flex gap-2"><FlaskConical aria-hidden="true" className="h-4 w-4 shrink-0 text-warning-700" /><div><dt className="font-semibold text-neutral-900">Test workspace</dt><dd className="mt-2 leading-5 text-neutral-600">A flexible protected copy for trying setup changes, payrolls, reports, or staff workflows. It cannot send live payroll actions.</dd></div></div>
            <div className="flex gap-2"><DatabaseBackup aria-hidden="true" className="h-4 w-4 shrink-0 text-neutral-600" /><div><dt className="font-semibold text-neutral-900">Read-only backup</dt><dd className="mt-2 leading-5 text-neutral-600">A sealed recovery copy made immediately before approved migration data changes the clean client.</dd></div></div>
          </dl>
        </div>
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">Workspace statuses</p>
          <dl className="mt-4 grid gap-4 text-sm sm:grid-cols-2">
            <div><dt><Badge variant="info">Preparing</Badge></dt><dd className="mt-2 leading-5 text-neutral-600">The protected copy is still being built.</dd></div>
            <div><dt><Badge variant="success">Ready to test</Badge></dt><dd className="mt-2 leading-5 text-neutral-600">The copy is verified and available to assigned staff.</dd></div>
            <div><dt><Badge variant="danger">Needs attention</Badge></dt><dd className="mt-2 leading-5 text-neutral-600">The copy did not finish. Review the error and retry.</dd></div>
            <div><dt><Badge variant="default">Read only</Badge></dt><dd className="mt-2 leading-5 text-neutral-600">The workspace is sealed and cannot be changed.</dd></div>
            <div><dt><Badge variant="default">Archived</Badge></dt><dd className="mt-2 leading-5 text-neutral-600">The workspace is hidden from the normal list but its evidence and audit history remain available.</dd></div>
          </dl>
        </div>
      </div>
    </details>
  );
}

export function WorkspaceRoleGuide(): ReactElement {
  return (
    <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
      <p className="text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">Access levels</p>
      <dl className="mt-4 grid gap-4 text-sm lg:grid-cols-3">
        <div><dt className="font-semibold text-neutral-900">Operator</dt><dd className="mt-2 leading-5 text-neutral-600">Changes test setup and processes practice payrolls.</dd></div>
        <div><dt className="font-semibold text-neutral-900">Reviewer</dt><dd className="mt-2 leading-5 text-neutral-600">Reviews workspace setup, payrolls, and reports without changing them.</dd></div>
        <div><dt className="font-semibold text-neutral-900">Workspace admin</dt><dd className="mt-2 leading-5 text-neutral-600">Manages this workspace and its assigned access.</dd></div>
      </dl>
      <p className="mt-4 border-t border-neutral-200 pt-4 text-xs leading-5 text-neutral-600">System admins already have full access and do not need to be assigned.</p>
    </div>
  );
}

export function TrainingWorkflowGuide(): ReactElement {
  const steps = [
    ['1', 'Complete Practice 1', 'Enter inputs, calculate, and compare it with the real payroll benchmark.'],
    ['2', 'Complete Practice 2', 'Move to the second payroll after the first exercise is approved.'],
    ['3', 'Review and approve', 'Approval completes each exercise. Training payrolls are never committed.'],
  ];

  return (
    <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4">
      <div className="flex items-center gap-2 text-sm font-semibold text-primary-950"><GraduationCap aria-hidden="true" className="h-4 w-4" />Training order</div>
      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        {steps.map(([number, title, description]) => (
          <div key={number} className="flex gap-2 rounded-lg bg-white/80 p-4">
            <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary-700 text-xs font-bold text-white">{number}</span>
            <div><p className="text-sm font-semibold text-neutral-900">{title}</p><p className="mt-2 text-xs leading-5 text-neutral-600">{description}</p></div>
          </div>
        ))}
      </div>
      <p className="mt-4 text-xs leading-5 text-primary-900">Earlier year-to-date payrolls are locked as the starting baseline. Recalculating Practice 1 resets Practice 2 so the sequence stays accurate.</p>
    </div>
  );
}
