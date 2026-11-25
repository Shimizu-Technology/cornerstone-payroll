// Help: the company's own contacts, set by its admins (M4-9a). With none set
// up, it says "Ask your manager at {company}", plus the company's main phone
// if there is one. It never falls back to Cornerstone (§8a).
import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { CircleHelp, Mail, MessageSquare, Phone } from 'lucide-react';
import { EmployeeApiError } from './api';
import { askManager, possessive } from './brand';
import { useEmployeeTerms } from './terms';
import type { HelpContact } from './contracts';
import { useBrand, useReadySession } from './contexts';
import { formatPhone, smsHref, telHref } from './format';
import { Card, LoadProblem, Page, Placeholder, SkeletonRows } from './ui';
import { isSessionError } from './useEmployeeData';

function CallCompany({ variant = 'primary' }: { variant?: 'primary' | 'secondary' }): ReactElement | null {
  const brand = useBrand();
  if (!brand.mainPhone || brand.isFallback) return null;
  return (
    <a href={telHref(brand.mainPhone)} className={`emp-btn emp-btn-${variant} emp-btn-block emp-narrow-button`}>
      <Phone aria-hidden="true" className="size-6" />
      Call {possessive(brand.name)} main line
    </a>
  );
}

/**
 * Under sign-in and on Welcome: generic, no named contacts before sign-in,
 * and the company's main phone only if the client shows it.
 */
export function CantSignIn(): ReactElement {
  const brand = useBrand();
  return (
    <details className="emp-details">
      <summary>Can't sign in?</summary>
      <div className="space-y-2 pt-2 text-neutral-700">
        <p>Forgot your password? Choose <strong>Forgot password?</strong> on the sign-in screen and we'll email you a code.</p>
        <p>On a new phone or computer, we'll email you a code to check it's you.</p>
        <p>{askManager(brand, 'Still stuck? Ask your manager')}</p>
        {brand.mainPhone && !brand.isFallback && (
          <p><a className="emp-link" href={telHref(brand.mainPhone)}>Call {formatPhone(brand.mainPhone)}</a></p>
        )}
      </div>
    </details>
  );
}

function ContactCard({ contact }: { contact: HelpContact }): ReactElement {
  return (
    <li className="emp-contact">
      <div className="min-w-0">
        <p className="emp-row-title break-words">{contact.name}</p>
        {contact.role && <p className="emp-row-sub">{contact.role}</p>}
      </div>
      <div className="emp-contact-actions">
        {contact.phone && (
          <a className="emp-btn emp-btn-primary emp-btn-small" href={telHref(contact.phone)} aria-label={`Call ${contact.name}, ${formatPhone(contact.phone)}`}>
            <Phone aria-hidden="true" className="size-5" />Call
          </a>
        )}
        {contact.phone && contact.textOk && (
          <a className="emp-btn emp-btn-secondary emp-btn-small" href={smsHref(contact.phone)} aria-label={`Text ${contact.name}`}>
            <MessageSquare aria-hidden="true" className="size-5" />Text
          </a>
        )}
        {contact.email && (
          <a className="emp-btn emp-btn-secondary emp-btn-small" href={`mailto:${contact.email}`} aria-label={`Email ${contact.name}, ${contact.email}`}>
            <Mail aria-hidden="true" className="size-5" />Email
          </a>
        )}
      </div>
    </li>
  );
}

const QUESTIONS: ReadonlyArray<{ q: string; a: (company: string) => string }> = [
  { q: 'Why is my pay different this time?', a: () => 'Open the pay stub and check the hours and each line. The line under take-home pay compares it with your last check when it can.' },
  { q: "My address or phone number changed", a: (company) => `Update your phone, email and emergency contacts in My info. A new home address is sent to ${company} to approve.` },
  { q: 'Where is my W-2GU?', a: () => 'In Tax forms, once it is posted. You also get a paper copy.' },
  { q: 'Something on my pay stub looks wrong', a: (company) => `Ask your manager at ${company}. They can check it with payroll.` },
];

type ContactsState = { status: 'loading' } | { status: 'ready'; contacts: HelpContact[] } | { status: 'error'; kind: 'offline' | 'rate_limited' | 'server' };

/**
 * Help contacts are optional on the API until M4-9 serves them, so only a 404
 * here means "none yet" (never "access ended"). A 401 or a two-step sign-in
 * 403 goes to the session like anywhere else; other failures offer Try again.
 */
function useHelpContacts(): { state: ContactsState; reload: () => void } {
  const { api, state, reportError } = useReadySession();
  const linkId = state.link.id;
  const [attempt, setAttempt] = useState(0);
  const [contacts, setContacts] = useState<ContactsState>({ status: 'loading' });
  useEffect(() => {
    const controller = new AbortController();
    setContacts({ status: 'loading' });
    api.helpContacts(linkId, controller.signal).then((list) => setContacts({ status: 'ready', contacts: list }), (error: unknown) => {
      if (controller.signal.aborted) return;
      if (error instanceof EmployeeApiError && error.kind === 'not_found') setContacts({ status: 'ready', contacts: [] });
      else if (isSessionError(error)) reportError(error);
      else {
        const kind = error instanceof EmployeeApiError && (error.kind === 'offline' || error.kind === 'rate_limited') ? error.kind : 'server';
        setContacts({ status: 'error', kind });
      }
    });
    return () => controller.abort();
  }, [api, linkId, reportError, attempt]);
  const reload = useCallback(() => setAttempt((n) => n + 1), []);
  return { state: contacts, reload };
}

export function HelpTab(): ReactElement {
  const { terms } = useEmployeeTerms();
  const brand = useBrand();
  const { state, reload } = useHelpContacts();
  const company = brand.isFallback ? 'your employer' : brand.name;
  return (
    <Page title="Help">
      <div className="emp-cards-grid">
        <Card title={brand.isFallback ? 'Questions about your pay?' : `Ask ${brand.name}`}>
          {state.status === 'loading' ? <SkeletonRows rows={2} label="Loading Help contacts" />
            : state.status === 'ready' && state.contacts.length > 0 ? (
              <div className="space-y-4">
                <p className="text-neutral-700">Questions about your pay or this app? These people can help.</p>
                <ul className="space-y-2">{state.contacts.map((contact, index) => <ContactCard key={`${index}-${contact.name}`} contact={contact} />)}</ul>
                <CallCompany variant="secondary" />
              </div>
            ) : (
              <div className="space-y-4">
                {state.status === 'error' && <LoadProblem kind={state.kind} onRetry={reload} what="the Help contacts" />}
                <Placeholder icon={CircleHelp} title="Questions about your pay or this app?">
                  <p>{askManager(brand)}</p>
                </Placeholder>
                <CallCompany />
              </div>
            )}
        </Card>
        <Card title="Common questions">
          <div className="emp-faq">
            {QUESTIONS.map(({ q, a }) => (
              <details key={q} className="emp-details">
                <summary>{q}</summary>
                <p className="pt-2 text-neutral-700">{a(company)}</p>
              </details>
            ))}
          </div>
        </Card>
        {terms && (
          <Card title="Terms and privacy">
            <ul className="space-y-1">
              <li><a className="emp-link" href={terms.termsUrl} target="_blank" rel="noreferrer">Employee App Terms</a></li>
              <li><a className="emp-link" href={terms.privacyUrl} target="_blank" rel="noreferrer">Privacy Notice</a></li>
            </ul>
          </Card>
        )}
      </div>
    </Page>
  );
}
