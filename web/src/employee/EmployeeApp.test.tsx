// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import EmployeeApp from '../EmployeeApp';
import { ViewOnlyBanner } from './ViewOnlyBanner';

function respond(routes: Record<string, () => Response>) {
  return vi.fn<typeof fetch>(async (input) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const handler = routes[path];
    return handler ? handler() : new Response(null, { status: 404 });
  });
}

const signedIn = () => sessionStorage.setItem('employee-dev-preview-signed-in', 'true');

beforeEach(() => {
  window.history.pushState({}, '', '/');
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

  it('asks the person to wait after a 429', async () => {
    signedIn();
    vi.stubGlobal('fetch', respond({ '/employee/links': () => new Response(null, { status: 429 }) }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'Too many tries, wait a minute' })).toBeTruthy();
    expect(screen.getByRole('navigation', { name: 'Main' })).toBeTruthy();
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

  it('sends a signed-out deep link to sign-in and back', async () => {
    window.history.pushState({}, '', '/taxes');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json([{ id: 3 }]),
      '/employee/context': () => new Response(null, { status: 204 }),
    }));
    render(<EmployeeApp />);

    await userEvent.click(await screen.findByRole('button', { name: 'Continue as preview employee' }));
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
    expect(banner.textContent).toContain('View only · 27 min left');
    await userEvent.click(within(banner).getByRole('button', { name: 'End' }));
    expect(onEnd).toHaveBeenCalledOnce();
  });

  it('leaves out the time when it isn\'t known', () => {
    render(<ViewOnlyBanner name="Milo Tarrant" onEnd={() => undefined} />);
    expect(screen.getByRole('region', { name: 'View only' }).textContent).not.toContain('min left');
  });
});
