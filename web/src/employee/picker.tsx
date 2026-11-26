import type { ReactElement } from 'react';
import { Building2, ChevronRight } from 'lucide-react';
import type { EmployeeLink } from './api';
import { today } from './config';
import { useDocumentTitle } from './hooks';
import { longDate, shortDate } from './format';
import { DemoPill, EmpButton } from './ui';

function lastPaidLabel(date: string | null): string | null {
  if (!date) return null;
  const formatted = date.slice(0, 4) === today().slice(0, 4) ? shortDate(date) : longDate(date);
  return formatted ? `Last paid ${formatted}` : null;
}

function linkSubtitle(link: EmployeeLink): string {
  const paid = lastPaidLabel(link.latestPayDate);
  if (link.status === 'former') {
    const parts = ['Former job'];
    if (paid) parts.push(paid);
    if (link.formerAccessUntil) parts.push(`view until ${longDate(link.formerAccessUntil)}`);
    return parts.join(' · ');
  }
  return paid ? `Current job · ${paid}` : 'Current job';
}

/**
 * For someone paid by more than one employer, on the shared host. A client's
 * own subdomain never shows this: it opens that client's link.
 */
export function EmployerPicker({ links, onChoose, onSignOut }: { links: EmployeeLink[]; onChoose: (linkId: string) => void; onSignOut: () => void }): ReactElement {
  useDocumentTitle('Choose an employer');
  return (
    <main className="emp-auth emp-auth-top">
      <div className="emp-auth-grow justify-start">
        <h1 className="emp-h1">Which job do you want to see?</h1>
        <p className="emp-lead">You can switch any time from My info.</p>
        <ul className="emp-rows w-full" aria-label="Employers">
          {links.map((link) => (
            <li key={link.id}>
              <button type="button" className="emp-row w-full text-left" onClick={() => onChoose(link.id)}>
                <span aria-hidden="true" className="grid size-11 shrink-0 place-items-center rounded-xl bg-[var(--action-tint)] text-[var(--action)]">
                  <Building2 className="size-6" />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="emp-row-title flex flex-wrap items-center gap-1.5">
                    <span className="min-w-0 [overflow-wrap:anywhere]">{link.companyName || 'Your employer'}</span>
                    {link.demo && <DemoPill />}
                  </span>
                  <span className="emp-row-sub">{linkSubtitle(link)}</span>
                </span>
                <ChevronRight aria-hidden="true" className="size-5 shrink-0 text-neutral-400" />
              </button>
            </li>
          ))}
        </ul>
      </div>
      <EmpButton variant="quiet" block onClick={onSignOut}>Sign out</EmpButton>
    </main>
  );
}
