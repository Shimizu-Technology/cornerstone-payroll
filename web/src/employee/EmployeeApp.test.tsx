// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// config.ts reads the Clerk key once, when it loads. Clear it before the app
// is imported, so a key in a developer's web/.env can't switch these tests to Clerk.
vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';
import { ViewOnlyBanner } from './ViewOnlyBanner';

function respond(routes: Record<string, () => Response>): ReturnType<typeof vi.fn<typeof fetch>> {
  return vi.fn<typeof fetch>(async (input) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const handler = routes[path];
    return handler ? handler() : new Response(null, { status: 404 });
  });
}

const signedIn = (): void => sessionStorage.setItem('employee-dev-preview-signed-in', 'true');

beforeEach(() => {
  window.history.pushState({}, '', '/');
});

afterAll(() => {
  vi.unstubAllEnvs();
});

afterEach(() => {
  cleanup();
  sessionStorage.clear();
  localStorage.clear();
  vi.unstubAllGlobals();
});

describe('employee app shell', () => {
  it('welcomes a signed-out visitor with the neutral brand', async () => {
    vi.stubGlobal('fetch', respond({}));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
    expect(document.title).toBe('Welcome · Cornerstone Payroll');
    expect(screen.getByRole('link', { name: 'Sign in' }).getAttribute('href')).toBe('/sign-in');
    expect(screen.getByText('See your pay stubs and tax forms any time.')).toBeTruthy();
  });

  it('opens the five tabs once the link checks out', async () => {
    signedIn();
    const fetchMock = respond({
      '/employee/links': () => Response.json({ links: [{ id: 42, company_name: "MoSa's", status: 'active' }] }),
      '/employee/context': () => new Response(null, { status: 204 }),
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Welcome' })).toBeTruthy();
    const nav = screen.getByRole('navigation', { name: 'Main' });
    expect(within(nav).getAllByRole('link').map((link) => link.textContent)).toEqual(['Home', 'Pay', 'Tax forms', 'My info', 'Help']);
    expect(within(nav).getByRole('link', { name: 'Home' }).getAttribute('aria-current')).toBe('page');

    const contextCall = fetchMock.mock.calls.find(([url]) => String(url).endsWith('/employee/context'));
    expect(contextCall?.[1]?.headers).toMatchObject({ 'X-Employee-Link-Id': '42', Authorization: 'Bearer dev-preview-token' });

    await userEvent.click(within(nav).getByRole('link', { name: 'Pay' }));
    const heading = await screen.findByRole('heading', { level: 1, name: 'Pay stubs' });
    expect(document.activeElement).toBe(heading);
    expect(screen.getByText('Your pay stubs will show here')).toBeTruthy();
  });

  it('remembers "Hide amounts" on this device', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    const first = render(<EmployeeApp />);
    await userEvent.click(await screen.findByRole('button', { name: 'Hide amounts' }));
    expect(screen.getByRole('button', { name: 'Show amounts' })).toBeTruthy();
    expect(localStorage.getItem('employee-app:hide-amounts')).toBe('true');
    first.unmount();

    render(<EmployeeApp />);
    expect(await screen.findByRole('button', { name: 'Show amounts' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Show amounts' }));
    expect(localStorage.getItem('employee-app:hide-amounts')).toBeNull();
  });

  it('points Help to the manager, never to Cornerstone', async () => {
    signedIn();
    window.history.pushState({}, '', '/help');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByText('Questions about your pay or this app?')).toBeTruthy();
    expect(screen.getByText('Ask your manager.')).toBeTruthy();
    expect(document.querySelector('main')?.textContent).not.toMatch(/Cornerstone/);
  });

  it('shows "isn\'t available" when the links endpoint answers 404', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({}));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: "The employee app isn't available right now" })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
    expect(screen.queryByRole('navigation', { name: 'Main' })).toBeNull();
  });

  it('sends a login that needs two-step sign-in to the Sign-in & security page, and back', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ error: 'Set up two-step sign-in.', code: 'mfa_enrollment_required' }, { status: 403 }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Set up two-step sign-in' })).toBeTruthy();
    await userEvent.click(screen.getByRole('link', { name: 'Set up two-step sign-in' }));

    expect(await screen.findByRole('heading', { level: 1, name: 'Sign-in & security' })).toBeTruthy();
    expect(window.location.pathname).toBe('/security');
    expect(document.title).toBe('Sign-in & security · Cornerstone Payroll');
    expect(screen.getByText('Two-step verification', { exact: false })).toBeTruthy();
    expect(screen.getByTestId('dev-preview-account-settings')).toBeTruthy();
    // The page opens without the employee session the API is refusing.
    expect(screen.queryByRole('navigation', { name: 'Main' })).toBeNull();

    await userEvent.click(screen.getByRole('link', { name: 'Done' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Set up two-step sign-in' })).toBeTruthy();
    expect(window.location.pathname).toBe('/');
  });

  it('asks an enrolled login that skipped the second step to sign in again, not to set it up', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ error: 'Multi-factor authentication is required.', code: 'mfa_required' }, { status: 403 }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Complete two-step sign-in' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Sign out and sign in again' })).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'Set up two-step sign-in' })).toBeNull();
  });

  it('links My info to Sign-in & security', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    const link = await within(await screen.findByRole('main')).findByRole('link', { name: 'Sign-in & security' });
    expect(link.getAttribute('href')).toBe('/security');
  });

  it('sends a signed-out visit to Sign-in & security through sign-in', async () => {
    window.history.pushState({}, '', '/security');
    vi.stubGlobal('fetch', respond({}));
    render(<EmployeeApp />);
    await screen.findByRole('heading', { level: 1 });
    expect(window.location.pathname).toBe('/sign-in');
  });

  it('shows "access ended" when former access has run out', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 9, company_name: "MoSa's", status: 'former', former_access_until: '2020-01-01' }]),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Your access has ended' })).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
  });

  it('asks the person to wait after a 429, with no dead-end tabs and a way to sign out', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({ '/employee/links': () => new Response(null, { status: 429 }) }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Too many tries, wait a minute' })).toBeTruthy();
    expect(screen.queryByRole('navigation', { name: 'Main' })).toBeNull();
    expect(screen.getByText('Still not working? Ask your manager.')).toBeTruthy();
    const main = screen.getByRole('main');
    await userEvent.click(within(main).getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
  });

  it.each([
    [undefined, 'This is the address on file for your W-2.'],
    ['handed_out', 'This is the address on file for your W-2.'],
    ['mailed', 'Your W-2 will be mailed here.'],
  ])('uses the reported W-2 delivery method (%s) on an approved address', async (delivery, expectedMessage) => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    const address = { address_line1: '100 Example Lane' };
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => Response.json({ w2_delivery: delivery, features: { profile_requests: true } }),
      '/employee/profile': () => Response.json({
        legal_name: 'Example Worker',
        ssn_last4: '0001',
        address,
        address_request: { id: 8, status: 'approved', requested: address, decision_note: 'Thanks for updating your address.' },
      }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByText(`Your new address was approved. ${expectedMessage}`)).toBeTruthy();
    expect(screen.getByText('Thanks for updating your address.')).toBeTruthy();
    expect(screen.getByText('To change these, ask your manager to put you in touch with Cornerstone.')).toBeTruthy();
    expect(screen.queryByText('Contact Cornerstone')).toBeNull();
    expect(screen.queryByText(/0001/)).toBeNull();
  });

  it('asks the employee to refresh and confirm their address when it changed before an edit', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    let requestCalls = 0;
    const address = { address_line1: '100 Example Lane', city: 'Example City', state: 'GU', zip: '96910' };
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => Response.json({ features: { profile_requests: true } }),
      '/employee/profile': () => Response.json({
        address,
        address_request: { id: 8, status: 'pending', requested: { ...address, address_line1: '200 Example Lane' } },
      }),
      '/employee/address_requests/8': () => (requestCalls++ === 0
        ? Response.json({ code: 'address_on_file_changed' }, { status: 409 })
        : Response.json({ address, address_request: { id: 8, status: 'cancelled', requested: { ...address, address_line1: '200 Example Lane' } } })),
    }));
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Edit request' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save request' }));
    expect(await screen.findByText('Your address on file was updated after you sent this request. Cancel this request, then send a new one if your address still needs to change.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Save request' })).toBeTruthy();

    // Recovery: close the form, cancel the stale request, then a new one can be sent.
    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Cancel request' }));
    expect(await screen.findByText('Request cancelled.')).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Request a change' })).toBeTruthy();
  });

  it('shows the daily limit in the email form without ending the session', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => Response.json({ features: { profile_requests: true } }),
      '/employee/profile': () => Response.json({ email: 'old@example.test' }),
      '/employee/profile/email': () => Response.json({ code: 'email_code_daily_limit' }, { status: 429 }),
    }));
    render(<EmployeeApp />);

    const emailCard = await screen.findByRole('region', { name: 'Contact details' });
    await userEvent.click(within(emailCard).getByRole('button', { name: 'Change personal email' }));
    const address = within(emailCard).getByRole('textbox');
    await userEvent.clear(address);
    await userEvent.type(address, 'new@example.test');
    await userEvent.click(within(emailCard).getByRole('button', { name: 'Send code' }));
    expect(await within(emailCard).findByText('Too many verification tries today. Try again tomorrow.')).toBeTruthy();
  });

  it('signs out from My info to the Welcome screen, not to sign-in', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    await userEvent.click(await within(await screen.findByRole('main')).findByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
    expect(window.location.pathname).toBe('/');
    expect(document.title).toBe('Welcome · Cornerstone Payroll');
  });

  it('shows the error screen and recovers on Try again', async () => {
    signedIn();
    let fail = true;
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => (fail ? new Response(null, { status: 500 }) : Response.json([{ id: 3 }])),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Something went wrong' })).toBeTruthy();
    fail = false;
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Welcome' })).toBeTruthy();
  });

  it('shows posted and withdrawn W-2GU copies from the tax forms API, with how the paper copy arrives', async () => {
    signedIn();
    window.history.pushState({}, '', '/taxes');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => Response.json({ w2_delivery: 'mailed', features: { tax_forms: true } }),
      '/employee/tax_forms': () => Response.json({ tax_forms: [
        { id: '12', tax_year: 2026, kind: 'w2gu', status: 'withdrawn', corrected: false, posted_at: '2027-01-20T00:00:00Z',
          pdf_available: false, available_through: '2027-10-15' },
        { id: '9', tax_year: 2025, kind: 'w2gu', status: 'posted', corrected: false, posted_at: '2026-01-20T00:00:00Z',
          pdf_available: true, available_through: '2026-10-15' },
      ] }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { name: '2026 W-2GU' })).toBeTruthy();
    expect(screen.getByText('A corrected form is being prepared')).toBeTruthy();
    expect(screen.getAllByRole('button', { name: 'Download W-2GU (PDF)' })).toHaveLength(1);
    expect(screen.getByRole('heading', { name: '2025 W-2GU' })).toBeTruthy();
    expect(screen.getAllByText('Your paper copy is mailed to your home address.')).toHaveLength(2);
  });

  it('keeps the tax forms list closed while the switch is off', async () => {
    signedIn();
    window.history.pushState({}, '', '/taxes');
    const fetchMock = respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => Response.json({ w2_delivery: 'handed_out', features: { tax_forms: false } }),
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    expect(await screen.findByText('Your tax forms will show here')).toBeTruthy();
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes('/employee/tax_forms'))).toBe(false);
  });

  it('sends a signed-out deep link to sign-in and back', async () => {
    window.history.pushState({}, '', '/taxes');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('button', { name: 'Continue as preview employee' })).toBeTruthy();
    expect(document.title).toBe('Sign in · Cornerstone Payroll');
    await userEvent.click(screen.getByRole('button', { name: 'Continue as preview employee' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Tax forms' })).toBeTruthy();
    expect(window.location.pathname).toBe('/taxes');
  });

  it('offers an Account menu in the header to switch employers or sign out from any screen', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({
        links: [
          { id: 10, company_name: 'Harbor Finch Kitchen', status: 'active', latest_pay_date: '2026-11-20' },
          { id: 11, company_name: 'Harbor Finch Catering', status: 'former', former_access_until: '2027-06-30', latest_pay_date: '2025-12-19' },
        ],
      }),
      '/employee/context': () => Response.json({ first_name: 'Maren', status: 'active', features: { stubs: false } }),
    }));
    render(<EmployeeApp />);

    // Employer picker shows latest pay date to tell jobs apart (E11).
    expect(await screen.findByRole('heading', { level: 1, name: 'Which job do you want to see?' })).toBeTruthy();
    expect(screen.getByText('Current job · Last paid Nov 20')).toBeTruthy();
    expect(screen.getByText('Former job · Last paid Dec 19, 2025 · view until Jun 30, 2027')).toBeTruthy();

    await userEvent.click(screen.getByRole('button', { name: /Harbor Finch Kitchen/ }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Hi, Maren' })).toBeTruthy();

    // Header Account menu exposes Switch employer, Sign-in & security, and Sign out (E2).
    const accountButton = screen.getByRole('button', { name: 'Account, Maren' });
    await userEvent.click(accountButton);
    const menu = screen.getByRole('navigation', { name: 'Account' });
    expect(within(menu).getByText('Maren')).toBeTruthy();
    expect(within(menu).getByRole('button', { name: 'Switch employer' })).toBeTruthy();
    expect(within(menu).getByRole('link', { name: 'Sign-in & security' })).toBeTruthy();
    await userEvent.click(within(menu).getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
  });

  it('labels unverified phone as "Added by you" and verified email as "Verified"', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3, company_name: 'Harbor Finch Kitchen', status: 'active' }]),
      '/employee/context': () => Response.json({ features: { profile_requests: true } }),
      '/employee/profile': () => Response.json({
        legal_name: 'Maren Fable',
        phone: '6715550142',
        phone_confirmed: true,
        email: 'maren@harborfinch.test',
        email_verified: true,
      }),
    }));
    render(<EmployeeApp />);

    const contact = await screen.findByRole('region', { name: 'Contact details' });
    expect(within(contact).getByText('Added by you')).toBeTruthy();
    expect(within(contact).getByText('Verified')).toBeTruthy();
    expect(within(contact).queryByText('Confirmed by you')).toBeNull();
  });

  it('opens Pay directly on the full list by year, titles stubs with the pay period, and uses Older/Newer', async () => {
    signedIn();
    window.history.pushState({}, '', '/pay');
    const stubs = [
      {
        id: 906,
        pay_period: { start_date: '2026-11-01', end_date: '2026-11-14', pay_date: '2026-11-20', run_purpose: 'regular' },
        check_date: '2026-11-20',
        gross_pay: '612.50',
        net_pay: '534.18',
        total_hours: '38.50',
        payment: { method: 'direct_deposit', status: 'issued', issued_on: '2026-11-20', check_number_last4: null },
        pdf_available: true,
      },
      {
        id: 905,
        pay_period: { start_date: '2026-10-18', end_date: '2026-10-31', pay_date: '2026-11-06', run_purpose: 'regular' },
        check_date: '2026-11-06',
        gross_pay: '651.00',
        net_pay: '570.63',
        total_hours: '42.00',
        payment: { method: 'direct_deposit', status: 'issued', issued_on: '2026-11-06', check_number_last4: null },
        pdf_available: true,
      },
    ];
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3, company_name: 'Harbor Finch Kitchen', status: 'active' }]),
      '/employee/context': () => Response.json({ features: { stubs: true } }),
      '/employee/statements': () => Response.json({ statements: stubs, years: [2026, 2025], next_page: null }),
      '/employee/statements/906': () => Response.json({ ...stubs[0], earnings: [], taxes: [], deductions: [], other_pay: [], ytd: { gross: '12000.00', net: '10000.00' } }),
      '/employee/statements/905': () => Response.json({ ...stubs[1], earnings: [], taxes: [], deductions: [], other_pay: [], ytd: { gross: '11387.50', net: '9465.82' } }),
    }));
    render(<EmployeeApp />);

    // Opens directly on the full list grouped by year, not a duplicate Latest pay overview (E10).
    expect(await screen.findByRole('heading', { level: 1, name: 'Pay stubs' })).toBeTruthy();
    const list = await screen.findByRole('list', { name: 'Paychecks' });
    expect(screen.getByRole('button', { name: '2026' })).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'View all pay stubs' })).toBeNull();
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);

    // Opening a stub titles it with the pay period and navigates via Older / Newer (E8, E9).
    await userEvent.click(within(list).getByRole('link', { name: /Nov 20/ }));
    const stub = await screen.findByRole('article');
    expect(within(stub).getByRole('heading', { level: 2, name: 'Nov 1 – 14' })).toBeTruthy();
    expect(within(stub).getByText('Paid Nov 20, 2026')).toBeTruthy();
    expect(within(stub).queryByText('Pay period Nov 1 – 14')).toBeNull();
    await userEvent.click(within(stub).getAllByRole('link', { name: /^Older:/ })[0]);
    const olderStub = await screen.findByRole('article');
    expect(within(olderStub).getByRole('heading', { level: 2, name: 'Oct 18 – 31' })).toBeTruthy();
    expect(within(olderStub).getAllByRole('link', { name: /^Newer:/ }).length).toBeGreaterThan(0);
  });

  it('sets honest Step 1 copy, hides internal terms version, and keeps Step 2 entries on mismatch', async () => {
    window.history.pushState({}, '', '/activate');
    let activationCalls = 0;
    let lastBody: Record<string, unknown> | null = null;
    vi.stubGlobal('fetch', vi.fn<typeof fetch>(async (input, init) => {
      const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
      if (path === '/public/employee_terms') {
        return Response.json({ version: '2026-11-25-draft-1', title: 'Employee App Terms', terms_url: '/terms', privacy_url: '/privacy' });
      }
      if (path === '/employee/activation') {
        activationCalls += 1;
        lastBody = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
        return Response.json({ code: 'activation_failed' }, { status: 422 });
      }
      return new Response(null, { status: 404 });
    }));
    render(<EmployeeApp />);

    // Honest Step 1 copy (E1).
    expect(await screen.findByText("First, tell us who you are. We'll check everything when you create your account.")).toBeTruthy();
    await userEvent.type(screen.getByLabelText('Sign-up code'), 'ABCDEFGHJK');
    await userEvent.selectOptions(screen.getByLabelText('Month'), '4');
    await userEvent.type(screen.getByLabelText('Day'), '7');
    await userEvent.type(screen.getByLabelText('Year'), '1990');
    await userEvent.type(screen.getByLabelText('Last 4 of your Social Security number'), '1234');
    await userEvent.click(screen.getByRole('button', { name: 'Continue' }));

    // Terms link shows title only, never the internal version code (E4).
    const termsLink = await screen.findByRole('link', { name: 'Employee App Terms' });
    expect(termsLink.textContent).toBe('Employee App Terms');
    expect(screen.queryByText(/2026-11-25-draft-1/)).toBeNull();

    await userEvent.type(screen.getByLabelText('Your email'), 'maren@harborfinch.test');
    await userEvent.click(screen.getByLabelText('Send my pay stub notices to this email'));
    await userEvent.click(screen.getByRole('checkbox', { name: /Employee App Terms/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Create account' }));

    // Sent back to Step 1 with the mismatch message, and the version was still sent in the request.
    expect(await screen.findByText("We couldn't match those details")).toBeTruthy();
    expect(activationCalls).toBe(1);
    expect(lastBody).toMatchObject({ terms_version: '2026-11-25-draft-1' });

    // Continuing back to Step 2 preserves the email, notice preference, and agreement (E1).
    await userEvent.click(screen.getByRole('button', { name: 'Continue' }));
    expect((await screen.findByLabelText('Your email') as HTMLInputElement).value).toBe('maren@harborfinch.test');
    expect((screen.getByLabelText('Send my pay stub notices to this email') as HTMLInputElement).checked).toBe(true);
    expect((screen.getByRole('checkbox', { name: /Employee App Terms/ }) as HTMLInputElement).checked).toBe(true);
  });
});

describe('ViewOnlyBanner', () => {
  it('names the person, says view only, and ends', async () => {
    const onEnd = vi.fn();
    render(<ViewOnlyBanner name="Milo Tarrant" minutesLeft={27} onEnd={onEnd} />);

    const banner = screen.getByRole('region', { name: 'View only' });
    expect(banner.textContent).toContain('Viewing as Milo Tarrant');
    expect(banner.textContent).toContain('27 min left');
    await userEvent.click(within(banner).getByRole('button', { name: 'End' }));
    expect(onEnd).toHaveBeenCalledOnce();
  });

  it('leaves out the time when it isn\'t known', () => {
    render(<ViewOnlyBanner name="Milo Tarrant" onEnd={() => undefined} />);
    expect(screen.getByRole('region', { name: 'View only' }).textContent).not.toContain('min left');
  });
});
