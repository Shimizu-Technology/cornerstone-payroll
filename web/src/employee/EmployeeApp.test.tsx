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
    expect(within(nav).getAllByRole('link').map((link) => link.textContent)).toEqual(['Home', 'Pay', 'Taxes', 'My info', 'Help']);
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
    expect(screen.getByText('Contact Cornerstone')).toBeTruthy();
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
