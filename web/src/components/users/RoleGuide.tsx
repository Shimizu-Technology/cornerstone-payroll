import type { ReactElement } from 'react';
import { ChevronDown } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import type { UserRole } from '@/types';

export interface RoleOption {
  value: UserRole;
  label: string;
  scope: string;
  can: string;
  cannot: string;
  assignment: string;
  legacy?: boolean;
  exceptional?: boolean;
}

// Collapsed by default, in the same style as Client Management's
// "Test workspace guide", so the user list stays the focus of the page.
export function RoleGuide({ roles }: { roles: RoleOption[] }): ReactElement {
  return (
    <details className="group mb-6 rounded-[1.35rem] border border-neutral-200/80 bg-white shadow-sm">
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 rounded-[1.35rem] px-4 py-4 marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2 sm:px-6">
        <div>
          <p className="text-sm font-semibold text-neutral-950">About roles</p>
          <p className="mt-2 text-xs leading-5 text-neutral-600">Choose the narrowest role that fits. Client assignments further limit managers, accountants and client portal users.</p>
        </div>
        <ChevronDown aria-hidden="true" className="h-5 w-5 shrink-0 text-neutral-500 transition-transform group-open:rotate-180" />
      </summary>
      <div className="border-t border-neutral-200 px-4 py-4 sm:px-6">
        <div className="mb-5 rounded-xl border border-neutral-200/80 bg-neutral-50 px-4 py-3 text-xs leading-5 text-neutral-700">
          <p className="font-semibold text-neutral-900">Client-managed employee lifecycle</p>
          <p className="mt-1">
            When a client uses client-managed mode, Client managers add, edit, terminate, and rehire employees directly without waiting for pre-approval.
            Incomplete setup blocks pay unless an Organization Admin grants a readiness override. Cornerstone is notified and verifies changes afterwards
            (Managers, Admins, and Accountants with Client management verify or send items back).
          </p>
        </div>
        <div className="grid gap-6 sm:grid-cols-2 xl:grid-cols-3">
          {roles.map(role => (
            <section key={role.value} aria-label={role.label}>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="text-sm font-semibold text-neutral-900">{role.label}</h3>
                {role.exceptional && <Badge variant="warning">Exceptional</Badge>}
              </div>
              <p className="mt-1 text-xs font-medium text-neutral-600">{role.scope}</p>
              <dl className="mt-3 space-y-2 text-xs leading-5">
                <div><dt className="font-semibold text-neutral-700">Can</dt><dd className="text-neutral-600">{role.can}</dd></div>
                <div><dt className="font-semibold text-neutral-700">Cannot</dt><dd className="text-neutral-600">{role.cannot}</dd></div>
                <div><dt className="font-semibold text-neutral-700">Assignment</dt><dd className="text-neutral-600">{role.assignment}</dd></div>
              </dl>
            </section>
          ))}
        </div>
      </div>
    </details>
  );
}

export function RoleHint({ role }: { role: RoleOption | undefined }): ReactElement | null {
  if (!role) return null;
  return <p className="mt-2 text-xs leading-5 text-neutral-600"><span className="font-semibold text-neutral-700">{role.label}:</span> {role.scope}. {role.assignment}</p>;
}
