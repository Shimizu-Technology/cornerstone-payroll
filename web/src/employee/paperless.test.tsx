// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';
import { inW2GuSeason, resetHiddenDeliveryCards, upcomingW2GuYear } from './paperlessState';

type Answer = 'paperless' | 'keep_paper' | 'not_answered';

const DISCLOSURE_TEXT = 'Purpose and scope\nElectronic pay statements under Guam UETA.\n\nRight to withdraw consent\nWithdraw in one tap.';

function consents({ pay = 'not_answered', w2 = 'not_answered', version = '2026-11-25-draft-1', text = DISCLOSURE_TEXT }: {
  pay?: Answer; w2?: Answer; version?: string; text?: string;
} = {}) {
  const item = (kind: 'pay_statements' | 'w2gu', answer: Answer) => ({
    kind,
    status: answer === 'paperless' ? 'consented' : 'not_consented',
    answer,
    paper_chosen_at: answer === 'keep_paper' ? '2026-11-27T00:00:00Z' : null,
    active_consent: answer === 'paperless'
      ? {
        id: kind === 'w2gu' ? 12 : 11,
        disclosure_version: '2026-11-25-draft-1',
        disclosure_digest: 'a'.repeat(64),
        given_at: '2026-11-27T00:00:00Z',
        method: kind === 'w2gu' ? 'employee_portal_pdf_verified' : 'employee_portal_checkbox',
        matches_current_disclosure: true,
      }
      : null,
    last_withdrawn_at: null,
    disclosure: {
      version,
      title: kind === 'w2gu' ? 'Electronic Form W-2GU Delivery Consent' : 'Electronic Pay Statement Delivery Consent',
      text,
      digest: 'a'.repeat(64),
      published_at: '2026-11-25T00:00:00Z',
      draft_marker: false,
    },
    requires_access_proof: kind === 'w2gu',
    email_notice_locked_on: false,
    paper_continues: true,
    electronic_only_ready: false,
  });
  return { paper_delivery_continues: true, consents: [item('pay_statements', pay), item('w2gu', w2)] };
}

function respond(routes: Record<string, (init?: RequestInit) => Response>): ReturnType<typeof vi.fn<typeof fetch>> {
  return vi.fn<typeof fetch>(async (input, init) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const key = `${init?.method ?? 'GET'} ${path}`;
    const handler = routes[key] ?? routes[path];
    return handler ? handler(init) : new Response(null, { status: 404 });
  });
}

function session({ deliveryConsent = true, status = 'active' }: { deliveryConsent?: boolean; status?: string } = {}) {
  return {
    '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status }] }),
    '/employee/context': () => Response.json({
      first_name: 'Jordan',
      status,
      ...(status === 'former' ? { former_access_until: '2027-06-30T23:59:59+10:00' } : {}),
      features: { stubs: false, tax_forms: true, profile_requests: false, delivery_consent: deliveryConsent },
    }),
  };
}

const posts = (fetchMock: ReturnType<typeof respond>) => fetchMock.mock.calls
  .filter(([, init]) => init?.method === 'POST')
  .map(([url, init]) => ({ path: new URL(String(url), 'http://localhost').pathname.replace(/^\/api\/v1/, ''), body: JSON.parse(String(init?.body ?? '{}')) as unknown }));

const REVERIFY = () => Response.json({
  clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level: 'second_factor', afterMinutes: 10 } } },
}, { status: 403 });
const verified = (init?: RequestInit) => new Headers(init?.headers).get('Authorization') === 'Bearer dev-preview-token-verified';
const UPDATED_TEXT = 'Purpose and scope\nUpdated wording for electronic pay statements.';

const signedIn = (): void => sessionStorage.setItem('employee-dev-preview-signed-in', 'true');

function openAt(path: string): void {
  signedIn();
  window.history.pushState({}, '', path);
}

const homeHeading = () => screen.findByRole('heading', { level: 1, name: 'Hi, Jordan' });
const payCard = () => screen.queryByRole('region', { name: 'Choose how you get pay stubs' });
const w2Card = () => screen.queryByRole('region', { name: 'Get your W-2GU online?' });

beforeEach(() => {
  window.history.pushState({}, '', '/');
});

afterAll(() => {
  vi.unstubAllEnvs();
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  sessionStorage.clear();
  localStorage.clear();
  resetHiddenDeliveryCards();
  vi.unstubAllGlobals();
});

describe('"Go paperless?" step', () => {
  it('follows account setup, once the new account is connected to the job', async () => {
    openAt('/sign-up/done');
    vi.stubGlobal('fetch', respond({
      ...session(),
      '/auth/me': () => Response.json({ user: { id: 1 } }),
      'GET /employee/delivery_consents': () => Response.json(consents()),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('button', { name: 'Yes, go paperless' })).toBeTruthy();
    expect(window.location.pathname).toBe('/go-paperless');
  });

  it('asks one plain question with three choices and no tabs', async () => {
    openAt('/go-paperless');
    vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Go paperless?' })).toBeTruthy();
    expect(await screen.findByText('Paper pay stubs keep coming for now.')).toBeTruthy();
    expect(screen.getByText('You can change it any time in My info.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Yes, go paperless' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Keep paper' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Decide later' })).toBeTruthy();
    expect(screen.queryByRole('navigation', { name: 'Main' })).toBeNull();
    // No legal wording on the step itself: the disclosure waits behind "Yes".
    expect(screen.queryByText('Electronic pay statements under Guam UETA.')).toBeNull();
    expect(document.body.textContent).not.toMatch(/\bpilot\b|UETA|consent/i);
  });

  it('Yes runs the pay statement consent with the full disclosure behind an expander and step-up, then opens Home', async () => {
    openAt('/go-paperless');
    let answer: Answer = 'not_answered';
    const fetchMock = respond({
      ...session(),
      'GET /employee/delivery_consents': () => Response.json(consents({ pay: answer })),
      'POST /employee/delivery_consents': (init) => {
        if (new Headers(init?.headers).get('Authorization') !== 'Bearer dev-preview-token-verified') {
          return Response.json({
            clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level: 'second_factor', afterMinutes: 10 } } },
          }, { status: 403 });
        }
        answer = 'paperless';
        return Response.json(consents({ pay: 'paperless' }), { status: 201 });
      },
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Yes, go paperless' }));
    const form = screen.getByRole('form', { name: 'Go paperless' });
    await vi.waitFor(() => expect(document.activeElement).toBe(within(form).getByRole('heading', { name: 'Go paperless' })));

    const toggle = within(form).getByRole('button', { name: 'Read the full disclosure' });
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(within(form).getByText('Electronic pay statements under Guam UETA.').closest('[hidden]')).not.toBeNull();
    await userEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(within(form).getByText('Electronic pay statements under Guam UETA.').closest('[hidden]')).toBeNull();

    const submit = within(form).getByRole('button', { name: 'Go paperless' });
    const checkbox = within(form).getByRole('checkbox', {
      name: 'I have read this disclosure and agree to electronic delivery of my pay statements.',
    });
    expect((submit as HTMLButtonElement).disabled).toBe(false);
    await userEvent.click(submit);
    expect(screen.getByRole('alert').textContent).toContain('To go paperless, check the box to agree.');
    expect(document.activeElement).toBe(checkbox);
    expect(posts(fetchMock)).toEqual([]);

    await userEvent.click(checkbox);
    await userEvent.click(submit);

    const dialog = await screen.findByTestId('dev-preview-step-up');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Confirm' }));

    expect(await homeHeading()).toBeTruthy();
    expect(screen.getByText("You're set to go paperless. Paper pay stubs still come for now.").closest('[role="status"]')).not.toBeNull();
    expect(payCard()).toBeNull();
    expect(posts(fetchMock).filter((call) => call.path === '/employee/delivery_consents').at(-1)?.body).toEqual({
      kind: 'pay_statements',
      acknowledged: true,
      disclosure_version: '2026-11-25-draft-1',
      disclosure_digest: 'a'.repeat(64),
    });
  });

  it('Back returns from the consent form to the three choices', async () => {
    openAt('/go-paperless');
    vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) }));
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Yes, go paperless' }));
    await userEvent.click(screen.getByRole('button', { name: 'Back' }));
    const yes = screen.getByRole('button', { name: 'Yes, go paperless' });
    await vi.waitFor(() => expect(document.activeElement).toBe(yes));
    expect(screen.queryByRole('form', { name: 'Go paperless' })).toBeNull();
  });

  it('Keep paper records the answer without step-up or consent, then opens Home without the card', async () => {
    openAt('/go-paperless');
    let answer: Answer = 'not_answered';
    const fetchMock = respond({
      ...session(),
      'GET /employee/delivery_consents': () => Response.json(consents({ pay: answer })),
      'POST /employee/delivery_consents/keep_paper': () => {
        answer = 'keep_paper';
        return Response.json(consents({ pay: 'keep_paper' }));
      },
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Keep paper' }));

    expect(await homeHeading()).toBeTruthy();
    expect(screen.getByText("Saved. You'll keep getting paper pay stubs.").closest('[role="status"]')).not.toBeNull();
    expect(payCard()).toBeNull();
    expect(screen.queryByTestId('dev-preview-step-up')).toBeNull();
    expect(posts(fetchMock)).toEqual([{ path: '/employee/delivery_consents/keep_paper', body: { kind: 'pay_statements' } }]);
  });

  it('Decide later saves nothing and opens Home, where the card keeps asking', async () => {
    openAt('/go-paperless');
    const fetchMock = respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Decide later' }));

    expect(await homeHeading()).toBeTruthy();
    expect(payCard()).toBeTruthy();
    expect(screen.getByRole('navigation', { name: 'Main' })).toBeTruthy();
    expect(posts(fetchMock)).toEqual([]);
  });

  it('shows a save problem in place and still lets the employee continue', async () => {
    openAt('/go-paperless');
    vi.stubGlobal('fetch', respond({
      ...session(),
      'GET /employee/delivery_consents': () => Response.json(consents()),
      'POST /employee/delivery_consents/keep_paper': () => new Response(null, { status: 500 }),
    }));
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Keep paper' }));
    expect((await screen.findByRole('alert')).textContent).toContain("Couldn't save your answer. Try again in a minute.");
    await userEvent.click(screen.getByRole('button', { name: 'Decide later' }));
    expect(await homeHeading()).toBeTruthy();
  });

  it('goes straight to Home when the employee already answered', async () => {
    openAt('/go-paperless');
    vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents({ pay: 'keep_paper' })) }));
    render(<EmployeeApp />);

    expect(await homeHeading()).toBeTruthy();
    expect(window.location.pathname).toBe('/');
    expect(payCard()).toBeNull();
  });

  it('goes straight to Home without asking when electronic delivery is off for the employer', async () => {
    openAt('/go-paperless');
    const fetchMock = respond(session({ deliveryConsent: false }));
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    expect(await homeHeading()).toBeTruthy();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes('/delivery_consents'))).toBe(false);
  });
});

describe('when the disclosure changes while agreeing', () => {
  it('on the step: clears the agreement, opens the new wording, and records consent only to it', async () => {
    openAt('/go-paperless');
    let version = '2026-11-25-draft-1';
    const bodies: Record<string, unknown>[] = [];
    vi.stubGlobal('fetch', respond({
      ...session(),
      'GET /employee/delivery_consents': () => Response.json(
        version === 'v2' ? consents({ version: 'v2', text: UPDATED_TEXT }) : consents(),
      ),
      'POST /employee/delivery_consents': (init) => {
        if (!verified(init)) return REVERIFY();
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        bodies.push(body);
        if (body.disclosure_version !== 'v2') {
          version = 'v2';
          return Response.json({ error: 'Updated', code: 'disclosure_outdated' }, { status: 422 });
        }
        return Response.json(consents({ pay: 'paperless', version: 'v2', text: UPDATED_TEXT }), { status: 201 });
      },
    }));
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Yes, go paperless' }));
    const form = screen.getByRole('form', { name: 'Go paperless' });
    await userEvent.click(within(form).getByRole('checkbox'));
    await userEvent.click(within(form).getByRole('button', { name: 'Go paperless' }));
    await userEvent.click(within(await screen.findByTestId('dev-preview-step-up')).getByRole('button', { name: 'Confirm' }));

    expect((await screen.findByRole('alert')).textContent).toContain('The disclosure was just updated. Read the new wording below, then check the box again to agree.');
    expect(document.body.textContent).not.toMatch(/Reload this page/);
    const updated = await within(form).findByText('Updated wording for electronic pay statements.');
    expect(updated.closest('[hidden]')).toBeNull();
    expect((within(form).getByRole('checkbox') as HTMLInputElement).checked).toBe(false);
    expect((within(form).getByRole('button', { name: 'Go paperless' }) as HTMLButtonElement).disabled).toBe(false);
    await userEvent.click(within(form).getByRole('button', { name: 'Go paperless' }));
    expect(screen.getByRole('alert').textContent).toContain('To go paperless, check the box to agree.');
    expect(bodies).toHaveLength(1);

    await userEvent.click(within(form).getByRole('checkbox'));
    await userEvent.click(within(form).getByRole('button', { name: 'Go paperless' }));
    expect(await homeHeading()).toBeTruthy();
    expect(bodies.map((body) => body.disclosure_version)).toEqual(['2026-11-25-draft-1', 'v2']);
  });

  it('on the My info card: clears the agreement and keeps the message with the new wording', async () => {
    openAt('/my-info');
    let version = '2026-11-25-draft-1';
    const bodies: Record<string, unknown>[] = [];
    vi.stubGlobal('fetch', respond({
      ...session(),
      '/employee/profile': () => Response.json({ legal_name: 'Jordan Reyes', email: 'jordan@example.test' }),
      'GET /employee/delivery_consents': () => Response.json(
        version === 'v2' ? consents({ version: 'v2', text: UPDATED_TEXT }) : consents(),
      ),
      'POST /employee/delivery_consents': (init) => {
        if (!verified(init)) return REVERIFY();
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        bodies.push(body);
        if (body.disclosure_version !== 'v2') {
          version = 'v2';
          return Response.json({ error: 'Updated', code: 'disclosure_outdated' }, { status: 422 });
        }
        return Response.json(consents({ pay: 'paperless', version: 'v2', text: UPDATED_TEXT }), { status: 201 });
      },
    }));
    render(<EmployeeApp />);

    const card = await screen.findByRole('region', { name: 'Electronic pay statements' });
    await userEvent.click(within(card).getByRole('checkbox'));
    await userEvent.click(within(card).getByRole('button', { name: 'Consent to electronic pay statements' }));
    await userEvent.click(within(await screen.findByTestId('dev-preview-step-up')).getByRole('button', { name: 'Confirm' }));

    const refreshed = await screen.findByRole('region', { name: 'Electronic pay statements' });
    expect(await within(refreshed).findByText('Updated wording for electronic pay statements.')).toBeTruthy();
    expect(within(refreshed).getByRole('alert').textContent).toContain('check the box again to agree');
    expect((within(refreshed).getByRole('checkbox') as HTMLInputElement).checked).toBe(false);
    expect((within(refreshed).getByRole('button', { name: 'Consent to electronic pay statements' }) as HTMLButtonElement).disabled).toBe(true);

    await userEvent.click(within(refreshed).getByRole('checkbox'));
    await userEvent.click(within(refreshed).getByRole('button', { name: 'Consent to electronic pay statements' }));
    expect(await screen.findByText(/Consent recorded for electronic pay statements/)).toBeTruthy();
    expect(bodies.map((body) => body.disclosure_version)).toEqual(['2026-11-25-draft-1', 'v2']);
  });
});

describe('after adding access on a login with two employers', () => {
  it('asks "Go paperless?" for the employer just added, without the employer picker', async () => {
    openAt('/claim');
    sessionStorage.setItem('employee-invite-token', 'abcdefghijklmnop1234');
    const askedFor: (string | null)[] = [];
    vi.stubGlobal('fetch', respond({
      '/public/employee_terms': () => Response.json({ version: 'terms-1', title: 'Employee App Terms', terms_url: '/terms', privacy_url: '/privacy' }),
      'POST /employee/links/claim': (init) => (verified(init)
        ? Response.json({ link: { id: 5, company_name: 'Second Shop', status: 'active' } }, { status: 201 })
        : REVERIFY()),
      '/employee/links': () => Response.json({ links: [
        { id: 3, company_name: 'Harbor Finch', status: 'active' },
        { id: 5, company_name: 'Second Shop', status: 'active' },
      ] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan', status: 'active', features: { stubs: false, tax_forms: true, profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': (init) => {
        askedFor.push(new Headers(init?.headers).get('X-Employee-Link-Id'));
        return Response.json(consents());
      },
    }));
    render(<EmployeeApp />);

    await userEvent.selectOptions(await screen.findByLabelText('Month'), '4');
    await userEvent.type(screen.getByLabelText('Day'), '7');
    await userEvent.type(screen.getByLabelText('Year'), '1990');
    await userEvent.type(screen.getByLabelText('Last 4 of your Social Security number'), '1234');
    await userEvent.click(await screen.findByRole('checkbox'));
    await userEvent.click(screen.getByRole('button', { name: 'Add access' }));
    await userEvent.click(within(await screen.findByTestId('dev-preview-step-up')).getByRole('button', { name: 'Confirm' }));

    expect(await screen.findByRole('button', { name: 'Yes, go paperless' })).toBeTruthy();
    expect(window.location.pathname).toBe('/go-paperless');
    expect(askedFor).toEqual(['5']);
  });
});

describe('Home cards', () => {
  it('asks about pay stubs until answered, and "Not now" hides the card for the rest of the visit', async () => {
    openAt('/');
    vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) }));
    const { unmount } = render(<EmployeeApp />);

    await homeHeading();
    const card = await screen.findByRole('region', { name: 'Choose how you get pay stubs' });
    expect(within(card).getByRole('link', { name: 'Choose' }).getAttribute('href')).toBe('/go-paperless');
    await userEvent.click(within(card).getByRole('button', { name: 'Not now: Choose how you get pay stubs' }));
    expect(payCard()).toBeNull();

    // A reload in the same tab keeps it hidden.
    unmount();
    resetHiddenDeliveryCards();
    render(<EmployeeApp />);
    await homeHeading();
    expect(payCard()).toBeNull();
  });

  it('opens the step from the card, where Decide later hides the card for this visit', async () => {
    openAt('/');
    vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) }));
    render(<EmployeeApp />);

    const card = await screen.findByRole('region', { name: 'Choose how you get pay stubs' });
    await userEvent.click(within(card).getByRole('link', { name: 'Choose' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Decide later' }));
    expect(await homeHeading()).toBeTruthy();
    expect(payCard()).toBeNull();
  });

  it('shows no pay card once answered either way', async () => {
    for (const pay of ['paperless', 'keep_paper'] as const) {
      openAt('/');
      vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents({ pay })) }));
      render(<EmployeeApp />);
      await homeHeading();
      await vi.waitFor(() => expect(screen.getByRole('main').getAttribute('aria-busy')).not.toBe('true'));
      expect(payCard()).toBeNull();
      cleanup();
    }
  });

  it('never asks a former employee or when electronic delivery is off', async () => {
    openAt('/');
    const fetchMock = respond({ ...session({ status: 'former' }), 'GET /employee/delivery_consents': () => Response.json(consents()) });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);
    expect(await screen.findByText("You're viewing your past pay")).toBeTruthy();
    expect(payCard()).toBeNull();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes('/delivery_consents'))).toBe(false);
    cleanup();

    const offMock = respond(session({ deliveryConsent: false }));
    vi.stubGlobal('fetch', offMock);
    render(<EmployeeApp />);
    await homeHeading();
    expect(payCard()).toBeNull();
    expect(offMock.mock.calls.some(([url]) => String(url).includes('/delivery_consents'))).toBe(false);
  });

  describe('W-2GU card, December 1 through January 31 in Guam', () => {
    const at = async (instant: string, w2: Answer = 'not_answered') => {
      vi.useFakeTimers({ toFake: ['Date'] });
      vi.setSystemTime(new Date(instant));
      openAt('/');
      vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents({ pay: 'keep_paper', w2 })) }));
      render(<EmployeeApp />);
      await homeHeading();
      // Wait for the consent answers to load before checking for absence.
      await vi.waitFor(() => expect(screen.getByRole('main').getAttribute('aria-busy')).not.toBe('true'));
    };

    it('is hidden on November 30 in Guam, even when it is already December elsewhere', async () => {
      await at('2026-11-30T13:59:00Z'); // 23:59 on Nov 30 in Guam
      expect(w2Card()).toBeNull();
    });

    it('shows from December 1 in Guam and links to the W-2GU consent on Tax forms', async () => {
      await at('2026-11-30T14:00:00Z'); // 00:00 on Dec 1 in Guam
      const card = await screen.findByRole('region', { name: 'Get your W-2GU online?' });
      expect(card.textContent).toContain('Your 2026 Form W-2GU comes by January 31.');
      expect(within(card).getByRole('link', { name: 'Choose for W-2GU' }).getAttribute('href')).toBe('/taxes');
      await userEvent.click(within(card).getByRole('button', { name: 'Not now: Get your W-2GU online?' }));
      expect(w2Card()).toBeNull();
      // No other card: focus goes to the page heading rather than getting lost.
      await vi.waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { level: 1, name: 'Hi, Jordan' })));
    });

    it('still shows on January 31 for last year’s form, and is gone on February 1', async () => {
      await at('2027-01-31T13:00:00Z'); // 23:00 on Jan 31 in Guam
      expect((await screen.findByRole('region', { name: 'Get your W-2GU online?' })).textContent).toContain('Your 2026 Form W-2GU');
      cleanup();
      await at('2027-01-31T14:00:00Z'); // 00:00 on Feb 1 in Guam
      expect(w2Card()).toBeNull();
    });

    it('moves focus to the remaining card when one is dismissed', async () => {
      vi.useFakeTimers({ toFake: ['Date'] });
      vi.setSystemTime(new Date('2026-12-15T02:00:00Z'));
      openAt('/');
      vi.stubGlobal('fetch', respond({ ...session(), 'GET /employee/delivery_consents': () => Response.json(consents()) }));
      render(<EmployeeApp />);
      const card = await screen.findByRole('region', { name: 'Choose how you get pay stubs' });
      await screen.findByRole('region', { name: 'Get your W-2GU online?' });
      await userEvent.click(within(card).getByRole('button', { name: 'Not now: Choose how you get pay stubs' }));
      await vi.waitFor(() => expect(document.activeElement).toBe(screen.getByRole('link', { name: 'Choose for W-2GU' })));
    });

    it('is hidden in season once the employee answered for W-2GU', async () => {
      await at('2026-12-15T02:00:00Z', 'keep_paper');
      expect(w2Card()).toBeNull();
      cleanup();
      await at('2026-12-15T02:00:00Z', 'paperless');
      expect(w2Card()).toBeNull();
    });
  });
});

describe('W-2GU season dates', () => {
  it('covers December 1 through January 31 in Guam days', () => {
    expect(inW2GuSeason(new Date('2026-11-30T13:59:59Z'))).toBe(false);
    expect(inW2GuSeason(new Date('2026-11-30T14:00:00Z'))).toBe(true);
    expect(inW2GuSeason(new Date('2026-12-31T12:00:00Z'))).toBe(true);
    expect(inW2GuSeason(new Date('2027-01-31T13:59:59Z'))).toBe(true);
    expect(inW2GuSeason(new Date('2027-01-31T14:00:00Z'))).toBe(false);
    expect(inW2GuSeason(new Date('2027-07-04T00:00:00Z'))).toBe(false);
  });

  it('names the tax year whose form is coming', () => {
    expect(upcomingW2GuYear(new Date('2026-12-02T00:00:00Z'))).toBe(2026);
    expect(upcomingW2GuYear(new Date('2027-01-15T00:00:00Z'))).toBe(2026);
  });
});

describe('Keep paper on the consent cards', () => {
  it('lets an employee who has not answered keep paper from My info', async () => {
    openAt('/my-info');
    let answer: Answer = 'not_answered';
    const fetchMock = respond({
      ...session(),
      '/employee/profile': () => Response.json({ legal_name: 'Jordan Reyes', email: 'jordan@example.test' }),
      'GET /employee/delivery_consents': () => Response.json(consents({ pay: answer })),
      'POST /employee/delivery_consents/keep_paper': () => {
        answer = 'keep_paper';
        return Response.json(consents({ pay: 'keep_paper' }));
      },
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    const card = await screen.findByRole('region', { name: 'Electronic pay statements' });
    await userEvent.click(within(card).getByRole('button', { name: 'Keep paper pay statements' }));
    expect(await screen.findByText("Saved. You'll keep getting paper pay statements.")).toBeTruthy();
    expect(within(card).getByText('Paper delivery (your choice)')).toBeTruthy();
    expect(within(card).queryByRole('button', { name: 'Keep paper pay statements' })).toBeNull();
    // Consent is still there for later.
    expect(within(card).getByRole('button', { name: 'Consent to electronic pay statements' })).toBeTruthy();
  });
});
