import type { ReactElement } from 'react';
import { Building2, ChevronRight } from 'lucide-react';
import type { EmployeeLink } from './api';
import { useDocumentTitle } from './hooks';
import { longDate } from './format';
import { EmpButton } from './ui';

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
                  <span className="emp-row-title block break-words">{link.companyName || 'Your employer'}</span>
                  <span className="emp-row-sub">
                    {link.status === 'former'
                      ? `Former job${link.formerAccessUntil ? ` · view until ${longDate(link.formerAccessUntil)}` : ''}`
                      : 'Current job'}
                  </span>
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
