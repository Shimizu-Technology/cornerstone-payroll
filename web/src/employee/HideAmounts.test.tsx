// @vitest-environment jsdom
import { act, cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';
import { parseStatementPage } from './contracts';
import { comparisonLine, splitCurrencySegments } from './format';
import { HIDE_AMOUNTS_EXPLAINED_KEY, HIDE_AMOUNTS_KEY } from './preferences';

const STATEMENTS_2026 = [
  {
    id: 906,
    pay_period: { start_date: '2026-11-01', end_date: '2026-11-14', pay_date: '2026-11-20', run_purpose: 'regular' },
    check_date: '2026-11-20',
    gross_pay: '612.50',
    net_pay: '534.18',
    total_hours: '38.50',
    payment: { method: 'paper_check', status: 'issued', issued_on: '2026-11-20', check_number_last4: '2187' },
    pdf_available: true,
    corrected: true,
    previous: { id: 905, pay_date: '2026-11-06', check_date: '2026-11-06', net_pay: '570.63', total_hours: '42.00' },
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
    corrected: false,
  },
  {
    id: 'qb_31',
    source: 'quickbooks',
    pay_date: '2026-08-28',
    period_start: '2026-08-09',
    period_end: '2026-08-22',
    gross_pay: '615.00',
    net_pay: '540.02',
    hours_total: '41.00',
    original_pdf: true,
    payment: { method: 'paper_check', status: null, issued_on: null, check_number_last4: '1088' },
    adjustment_note: 'Includes recorded payroll adjustments.',
  },
];

const DETAIL_906 = {
  ...STATEMENTS_2026[0],
  earnings: [
    { label: 'Regular', hours: '36.00', rate: '15.00', amount: '540.00', ytd: '24300.00', kind: 'regular' },
    { label: 'Overtime', hours: '2.50', rate: '22.50', amount: '56.25', ytd: '900.00', kind: 'overtime' },
    { label: 'Tips', hours: null, rate: null, amount: '16.25', ytd: '1200.00', kind: 'tips' },
  ],
  taxes: [
    { label: 'Federal/Guam Income Tax', amount: '24.50', ytd: '1100.00' },
    { label: 'Social Security (6.2%)', amount: '37.98', ytd: '1580.00' },
    { label: 'Medicare (1.45%)', amount: '8.88', ytd: '370.00' },
  ],
  deductions: [{ label: 'Uniform', amount: '6.96', ytd: '120.00' }],
  other_pay: [{ label: 'Tool stipend', amount: '12.34', ytd: '98.72' }],
  ytd: { gross: '26400.00', net: '23230.00' },
  note: null,
  earlier_versions: [
    { id: '906_rev1', status: 'replaced', posted_at: '2026-11-20T08:00:00Z', payment_line: 'Check #2187' },
    { id: '906_orig', status: 'replaced', posted_at: '2026-11-19T08:00:00Z', payment_line: 'Check #2186' },
  ],
};

const DETAIL_QB = {
  ...STATEMENTS_2026[2],
  earnings: [{ label: 'Gross pay', hours: '41.00', rate: null, amount: '615.00', ytd: null, kind: null }],
  taxes: [{ label: 'Guam Income Tax', amount: '74.98', ytd: null }],
  deductions: [],
  other_pay: [],
  ytd: { gross: null, net: null },
  note: 'Includes recorded payroll adjustments.',
  earlier_versions: [],
};

// Every money figure present in the fixture payloads, in formatted and raw forms.
const FORBIDDEN_AMOUNTS = [
  '534.18',
  '612.50',
  '570.63',
  '651.00',
  '540.02',
  '615.00',
  '540.00',
  '24,300',
  '24300',
  '15.00',
  '22.50',
  '56.25',
  '900.00',
  '16.25',
  '1,200',
  '1200',
  '24.50',
  '1,100',
  '1100',
  '37.98',
  '1,580',
  '1580',
  '8.88',
  '370.00',
  '6.96',
  '120.00',
  '12.34',
  '98.72',
  '74.98',
  '26,400',
  '26400',
  '23,230',
  '23230',
  '36.45',
];

const LEAKED_CURRENCY_PATTERN = /\$\s*[-+]?(?:\d|\.\d)|\bUSD\s*[-+]?(?:\d|\.\d)|(?:\d|\.\d)\s*USD\b/i;

function mockEmployeeRoutes(overrides: Record<string, () => Response> = {}): ReturnType<typeof vi.fn<typeof fetch>> {
  const routes: Record<string, () => Response> = {
    '/employee/links': () => Response.json({
      links: [{ id: 42, company_name: 'Harbor Finch Kitchen', status: 'active' }],
    }),
    '/employee/context': () => Response.json({
      first_name: 'Maren',
      status: 'active',
      next_payday: '2026-12-04',
      w2_delivery: 'mailed',
      features: { stubs: true, tax_forms: true, profile_requests: true },
    }),
    '/employee/statements': () => Response.json({
      statements: STATEMENTS_2026,
      years: [2026],
      next_page: null,
    }),
    '/employee/statements/906': () => Response.json(DETAIL_906),
    '/employee/statements/qb_31': () => Response.json(DETAIL_QB),
    '/employee/tax_forms': () => Response.json({
      tax_forms: [
        { id: '12', tax_year: 2026, kind: 'w2gu', status: 'withdrawn', corrected: false },
        { id: '9', tax_year: 2025, kind: 'w2gu', status: 'posted', corrected: false },
      ],
    }),
    '/employee/profile': () => Response.json({
      legal_name: 'Maren Fable',
      email: 'maren@harborfinch.test',
      email_verified: true,
      phone: '6715550142',
      phone_confirmed: true,
      payment_method: 'direct_deposit',
      address: { address_line1: '100 Example Rd', city: 'Tamuning', state: 'GU', zip: '96913' },
      emergency_contacts: [{ id: 1, name: 'Avery Fable', relationship: 'Sibling', phone: '6715550199' }],
    }),
    '/employee/help': () => Response.json({
      help_contacts: [{ name: 'Rina Calvo', role: 'Manager', phone: '6715550110', email: 'rina@harborfinch.test', text_ok: true }],
    }),
    ...overrides,
  };
  return vi.fn<typeof fetch>(async (input) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const handler = routes[path];
    return handler ? handler() : new Response(null, { status: 404 });
  });
}

/**
 * Scans document.title, visible text, EVERY attribute of EVERY node, inline
 * filter styles, and loading state to verify zero money amounts leak while
 * masked and CSS blur is never used.
 */
function expectMaskedDomClean(root: HTMLElement, extraForbidden: string[] = []): void {
  const forbidden = [...FORBIDDEN_AMOUNTS, ...extraForbidden];

  // Ensure every async section finished loading before scanning.
  expect(root.querySelectorAll('[aria-busy="true"]').length, 'async section still loading during leak scan').toBe(0);

  expect(document.title, 'document.title leaked currency').not.toMatch(LEAKED_CURRENCY_PATTERN);
  for (const figure of forbidden) {
    expect(document.title, `document.title leaked ${figure}`).not.toContain(figure);
  }

  const text = root.textContent ?? '';
  expect(text, 'visible text leaked currency').not.toMatch(LEAKED_CURRENCY_PATTERN);
  for (const figure of forbidden) {
    expect(text, `visible text leaked ${figure}`).not.toContain(figure);
  }

  for (const node of root.querySelectorAll<HTMLElement>('*')) {
    for (const attr of Array.from(node.attributes)) {
      const value = attr.value;
      if (!value) continue;
      expect(value, `${node.tagName.toLowerCase()}[${attr.name}] leaked currency`).not.toMatch(LEAKED_CURRENCY_PATTERN);
      for (const figure of forbidden) {
        expect(value, `${node.tagName.toLowerCase()}[${attr.name}] leaked ${figure}`).not.toContain(figure);
      }
    }
    expect(node.style.filter, 'CSS blur must never be used for masking').not.toMatch(/blur/i);
  }
}

const signedIn = (): void => sessionStorage.setItem('employee-dev-preview-signed-in', 'true');

beforeEach(() => {
  window.history.pushState({}, '', '/');
  signedIn();
  vi.stubGlobal('fetch', mockEmployeeRoutes());
});

afterAll(() => {
  vi.unstubAllEnvs();
});

afterEach(() => {
  cleanup();
  sessionStorage.clear();
  try {
    localStorage.clear();
  } catch {
    // Some tests stub localStorage to throw.
  }
  vi.unstubAllGlobals();
});

describe('Employee app masked pay amounts by default (Track K)', () => {
  it('catches injected money in data-* attributes, plain text, document.title, CSS blur and unfinished loading (negative control)', () => {
    const root = document.createElement('div');
    root.innerHTML = '<p>Safe text <span>$•••</span></p>';
    document.title = 'Home · Cornerstone Payroll';
    expect(() => expectMaskedDomClean(root)).not.toThrow();

    const withDataAttr = document.createElement('div');
    withDataAttr.innerHTML = '<span data-net="$123.45">$•••</span>';
    expect(() => expectMaskedDomClean(withDataAttr)).toThrow(/data-net/);

    const withPlainText = document.createElement('div');
    withPlainText.innerHTML = '<p>Take-home 534.18</p>';
    expect(() => expectMaskedDomClean(withPlainText)).toThrow(/534\.18/);

    const withBlur = document.createElement('div');
    withBlur.innerHTML = '<span style="filter: blur(6px)">$•••</span>';
    expect(() => expectMaskedDomClean(withBlur)).toThrow(/blur/i);

    const stillLoading = document.createElement('div');
    stillLoading.innerHTML = '<div aria-busy="true">Loading</div>';
    expect(() => expectMaskedDomClean(stillLoading)).toThrow(/still loading/i);

    document.title = 'Pay $123.45';
    expect(() => expectMaskedDomClean(root)).toThrow(/document\.title/);
    document.title = 'Home · Cornerstone Payroll';
  });

  it('masks Home (including async YTD) by default while keeping hours comparison, dates and payment method visible', async () => {
    const { container } = render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('link', { name: 'View pay stub' });

    // Wait for async "This year so far" (YearSoFar) to finish loading before scanning.
    const yearSoFar = screen.getByRole('region', { name: 'This year so far' });
    await within(yearSoFar).findByText('2026 through Nov 20');
    expect(within(yearSoFar).getAllByText('Amount hidden')).toHaveLength(2);

    const toggle = within(latest).getByRole('button', { name: 'Show amounts' });
    expect(toggle.getAttribute('aria-pressed')).toBeNull();
    expect(latest.textContent).toContain('$•••');
    expect(within(latest).getAllByText('Amount hidden').length).toBeGreaterThan(0);

    // Non-money details and hours-only comparison stay visible while masked.
    expect(latest.textContent).toContain('Paid Nov 20, 2026');
    expect(latest.textContent).toContain('Check #2187');
    expect(latest.textContent).toContain('38.5 hours');
    expect(latest.textContent).toContain('You worked 3.5 fewer hours than Nov 6.');
    expect(latest.textContent).not.toContain('less than');

    // Every screen region (including Recent pay and loaded YearSoFar) leaks no amounts.
    expectMaskedDomClean(container);

    // Tapping Show amounts reveals amounts and the full money + hours comparison.
    await userEvent.click(toggle);
    expect(within(latest).getByRole('button', { name: 'Hide amounts' }).getAttribute('aria-pressed')).toBeNull();
    expect(latest.textContent).toContain('$534.18');
    expect(latest.textContent).toContain('$36.45 less than Nov 6. You worked 3.5 fewer hours.');
    expect(yearSoFar.textContent).toContain('$23,230.00');
    expect(yearSoFar.textContent).toContain('$26,400.00');
  });

  it('masks the Pay list by default while keeping dates and hours visible', async () => {
    window.history.pushState({}, '', '/pay');
    const { container } = render(<EmployeeApp />);
    const list = await screen.findByRole('list', { name: 'Paychecks' });
    const qbList = await screen.findByRole('list', { name: 'From QuickBooks records' });
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);
    expect(within(qbList).getAllByRole('listitem')).toHaveLength(1);

    expect(screen.getByRole('button', { name: 'Show amounts' }).getAttribute('aria-pressed')).toBeNull();
    expect(list.textContent).toContain('Nov 20');
    expect(list.textContent).toContain('38.5 hours');
    expect(list.textContent).toContain('$•••');
    expect(within(list).getAllByText('Amount hidden').length).toBeGreaterThan(0);
    expectMaskedDomClean(container);
  });

  it('masks Stub detail including pay rates and labels every PDF download with "(shows amounts)"', async () => {
    window.history.pushState({}, '', '/pay/906');
    const { container } = render(<EmployeeApp />);
    const stub = await screen.findByRole('article');
    await within(stub).findByRole('region', { name: 'This year so far' });

    // Dates, payment method, hours and hours-only comparison remain visible; rates are masked with dots.
    expect(stub.textContent).toContain('Nov 1 – 14, 2026');
    expect(stub.textContent).toContain('Paid Nov 20, 2026');
    expect(stub.textContent).toContain('Check #2187');
    expect(stub.textContent).toContain('38.5 hours');
    expect(stub.textContent).toContain('You worked 3.5 fewer hours than Nov 6.');
    expect(stub.textContent).toContain('36 hrs × $•••');
    expect(stub.textContent).toContain('2.5 hrs × $•••');
    expect(within(stub).getAllByText('Amount hidden').length).toBeGreaterThan(0);

    // Every PDF button warns that it shows amounts while masked.
    expect(within(stub).getByRole('button', { name: 'Download PDF (shows amounts)' })).toBeTruthy();
    await userEvent.click(within(stub).getByText('Corrected — see the original'));
    expect(within(stub).getByRole('button', { name: 'Download earlier PDF (shows amounts)' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download original PDF (shows amounts)' })).toBeTruthy();

    expectMaskedDomClean(container);

    // Unmasking reveals rates, amounts, full comparison and base PDF labels.
    await userEvent.click(screen.getByRole('button', { name: 'Show amounts' }));
    expect(stub.textContent).toContain('36 hrs × $15.00');
    expect(stub.textContent).toContain('2.5 hrs × $22.50');
    expect(stub.textContent).toContain('$534.18');
    expect(stub.textContent).toContain('$36.45 less than Nov 6. You worked 3.5 fewer hours.');
    expect(stub.textContent).toContain('$23,230.00');
    expect(within(stub).getByRole('button', { name: 'Download PDF' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download earlier PDF' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download original PDF' })).toBeTruthy();
  });

  it('masks currency in QuickBooks stub notes and imported line labels while leaving non-money text intact', async () => {
    window.history.pushState({}, '', '/pay/qb_31');
    const first = render(<EmployeeApp />);
    const stub = await screen.findByRole('article');
    expect(within(stub).getByText('Includes recorded payroll adjustments.')).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'View original stub PDF (shows amounts)' })).toBeTruthy();
    expectMaskedDomClean(first.container);
    first.unmount();

    // Defense in depth: currency formats in notes or imported QuickBooks line labels are masked while hidden.
    vi.stubGlobal('fetch', mockEmployeeRoutes({
      '/employee/statements/qb_31': () => Response.json({
        ...DETAIL_QB,
        earnings: [
          { label: 'Holiday bonus (USD 45.67)', hours: '8.00', rate: null, amount: '45.67', ytd: null, kind: null },
        ],
        deductions: [
          { label: 'Meal credit ($12.50)', amount: '12.50', ytd: null },
        ],
        adjustment_note: 'Adjusted by $-45.00 and $.50 (45.67 USD) on Check #1088 for 36.5 hrs on 2026-08-28.',
        note: 'Adjusted by $-45.00 and $.50 (45.67 USD) on Check #1088 for 36.5 hrs on 2026-08-28.',
      }),
    }));
    const second = render(<EmployeeApp />);
    const stubWithCurrencyText = await screen.findByRole('article');
    expect(stubWithCurrencyText.textContent).toContain('Check #1088');
    expect(stubWithCurrencyText.textContent).toContain('36.5 hrs');
    expect(stubWithCurrencyText.textContent).toContain('2026-08-28');
    expectMaskedDomClean(second.container, ['45.00', '45.67', '.50', '12.50']);
  });

  it('hides the eye toggle on screens with no rendered amounts (Tax forms, stubs off, empty stubs) while keeping W-2GU PDF warning', async () => {
    window.history.pushState({}, '', '/taxes');
    const taxes = render(<EmployeeApp />);
    expect(await screen.findByRole('heading', { name: '2026 W-2GU' })).toBeTruthy();
    expect(await screen.findByRole('button', { name: 'Download W-2GU PDF (shows amounts)' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    expectMaskedDomClean(taxes.container);
    taxes.unmount();

    // My info and Help also have no toggle and expose no money.
    window.history.pushState({}, '', '/my-info');
    const myInfo = render(<EmployeeApp />);
    expect(await screen.findByText('Direct deposit')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    expectMaskedDomClean(myInfo.container);
    myInfo.unmount();

    window.history.pushState({}, '', '/help');
    const help = render(<EmployeeApp />);
    expect(await screen.findByText('Rina Calvo')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    expectMaskedDomClean(help.container);
    help.unmount();

    // Home and Pay when stubs feature is off: no eye toggle.
    vi.stubGlobal('fetch', mockEmployeeRoutes({
      '/employee/context': () => Response.json({
        first_name: 'Maren',
        status: 'active',
        features: { stubs: false, tax_forms: false, profile_requests: false },
      }),
    }));
    window.history.pushState({}, '', '/');
    const homeOff = render(<EmployeeApp />);
    expect(await screen.findByText('Your latest pay will show here')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    homeOff.unmount();

    window.history.pushState({}, '', '/pay');
    const payOff = render(<EmployeeApp />);
    expect(await screen.findByText('Your pay stubs will show here')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    payOff.unmount();

    // Home and Pay when stubs are enabled but employee has no pay stubs yet: no eye toggle.
    vi.stubGlobal('fetch', mockEmployeeRoutes({
      '/employee/statements': () => Response.json({ statements: [], years: [], next_page: null }),
    }));
    window.history.pushState({}, '', '/');
    const homeEmpty = render(<EmployeeApp />);
    expect(await screen.findByText('No pay stubs yet')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
    homeEmpty.unmount();
  });

  it('shows the one-time explainer once, dismisses it on navigation in the same session, and never repeats it on reload', async () => {
    const explainerText = 'Amounts stay hidden on this device until you tap Show amounts.';
    const first = render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('button', { name: 'Show amounts' });
    expect(screen.getByText(explainerText)).toBeTruthy();
    expect(localStorage.getItem(HIDE_AMOUNTS_EXPLAINED_KEY)).toBe('true');

    // Navigating to Pay during the same first session dismisses the explainer without needing a toggle click.
    await userEvent.click(within(screen.getByRole('navigation', { name: 'Main' })).getByRole('link', { name: 'Pay' }));
    await screen.findByRole('list', { name: 'Paychecks' });
    expect(screen.queryByText(explainerText)).toBeNull();

    // Opening a stub also does not repeat the explainer.
    await userEvent.click(within(screen.getByRole('list', { name: 'Paychecks' })).getByRole('link', { name: /Nov 20/ }));
    await screen.findByRole('article');
    expect(screen.queryByText(explainerText)).toBeNull();
    first.unmount();

    // Second page load on the same device: still masked, no explainer repeat.
    window.history.pushState({}, '', '/');
    const second = render(<EmployeeApp />);
    const showButton = await screen.findByRole('button', { name: 'Show amounts' });
    expect(screen.queryByText(explainerText)).toBeNull();

    await userEvent.click(showButton);
    await userEvent.click(screen.getByRole('button', { name: 'Hide amounts' }));
    expect(screen.queryByText(explainerText)).toBeNull();
    second.unmount();
  });

  it('announces "Amounts shown" and "Amounts hidden" in a persistent live region on toggle', async () => {
    const { container } = render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('link', { name: 'View pay stub' });
    await within(screen.getByRole('region', { name: 'This year so far' })).findByText('2026 through Nov 20');

    // Persistent, initially empty live region is mounted before any toggle.
    const liveRegion = container.querySelector('[role="status"][aria-live="polite"]') as HTMLElement | null;
    expect(liveRegion).not.toBeNull();
    expect(liveRegion?.textContent).toBe('');

    await userEvent.click(within(latest).getByRole('button', { name: 'Show amounts' }));
    expect(container.querySelector('[role="status"][aria-live="polite"]')).toBe(liveRegion);
    expect(liveRegion?.textContent).toBe('Amounts shown');

    await userEvent.click(within(latest).getByRole('button', { name: 'Hide amounts' }));
    expect(container.querySelector('[role="status"][aria-live="polite"]')).toBe(liveRegion);
    expect(liveRegion?.textContent).toBe('Amounts hidden');
  });

  it('syncs visibility across open tabs via the storage event', async () => {
    render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('link', { name: 'View pay stub' });
    expect(latest.textContent).not.toContain('$534.18');

    // Another tab reveals amounts.
    act(() => {
      localStorage.setItem(HIDE_AMOUNTS_KEY, 'false');
      window.dispatchEvent(new StorageEvent('storage', { key: HIDE_AMOUNTS_KEY, newValue: 'false' }));
    });
    expect(latest.textContent).toContain('$534.18');
    expect(within(latest).getByRole('button', { name: 'Hide amounts' })).toBeTruthy();

    // Another tab hides amounts again.
    act(() => {
      localStorage.setItem(HIDE_AMOUNTS_KEY, 'true');
      window.dispatchEvent(new StorageEvent('storage', { key: HIDE_AMOUNTS_KEY, newValue: 'true' }));
    });
    expect(latest.textContent).not.toContain('$534.18');
    expect(within(latest).getByRole('button', { name: 'Show amounts' })).toBeTruthy();

    // Another tab clears storage -> fails closed to masked.
    act(() => {
      localStorage.setItem(HIDE_AMOUNTS_KEY, 'false');
      window.dispatchEvent(new StorageEvent('storage', { key: HIDE_AMOUNTS_KEY, newValue: 'false' }));
    });
    expect(latest.textContent).toContain('$534.18');
    act(() => {
      localStorage.clear();
      window.dispatchEvent(new StorageEvent('storage', { key: null, newValue: null }));
    });
    expect(latest.textContent).not.toContain('$534.18');
  });

  it('keeps the per-device visibility choice across sign-out and sign-in', async () => {
    render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('link', { name: 'View pay stub' });

    await userEvent.click(within(latest).getByRole('button', { name: 'Show amounts' }));
    expect(localStorage.getItem(HIDE_AMOUNTS_KEY)).toBe('false');
    expect(latest.textContent).toContain('$534.18');

    // Sign out from the header.
    await userEvent.click(screen.getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeTruthy();
    expect(localStorage.getItem(HIDE_AMOUNTS_KEY)).toBe('false');

    // Sign back in on the same device: amounts stay shown.
    await userEvent.click(screen.getByRole('link', { name: 'Sign in' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Continue as preview employee' }));
    const latestAfter = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latestAfter).findByRole('link', { name: 'View pay stub' });
    expect(within(latestAfter).getByRole('button', { name: 'Hide amounts' })).toBeTruthy();
    expect(latestAfter.textContent).toContain('$534.18');
  });

  it('falls back to masked when localStorage is blocked or throws', async () => {
    const originalDescriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      get(): never {
        throw new DOMException('The operation is insecure.', 'SecurityError');
      },
    });
    try {
      const first = render(<EmployeeApp />);
      const latest = await screen.findByRole('region', { name: 'Latest pay' });
      await within(latest).findByRole('link', { name: 'View pay stub' });
      await within(screen.getByRole('region', { name: 'This year so far' })).findByText('2026 through Nov 20');

      expect(within(latest).getByRole('button', { name: 'Show amounts' })).toBeTruthy();
      expectMaskedDomClean(first.container);

      // In-memory toggle still works without throwing.
      await userEvent.click(within(latest).getByRole('button', { name: 'Show amounts' }));
      expect(latest.textContent).toContain('$534.18');
      first.unmount();

      // Reloading with blocked storage fails closed to masked again.
      const second = render(<EmployeeApp />);
      const latestReloaded = await screen.findByRole('region', { name: 'Latest pay' });
      await within(latestReloaded).findByRole('link', { name: 'View pay stub' });
      await within(screen.getByRole('region', { name: 'This year so far' })).findByText('2026 through Nov 20');
      expect(within(latestReloaded).getByRole('button', { name: 'Show amounts' })).toBeTruthy();
      expectMaskedDomClean(second.container);
    } finally {
      if (originalDescriptor) Object.defineProperty(window, 'localStorage', originalDescriptor);
    }
  });
});

describe('currency masking helper and hours-only comparison', () => {
  it.each([
    ['standard dollar', 'Bonus $45.00 paid', ['$45.00']],
    ['negative before dollar', 'Adjustment -$45.00 applied', ['-$45.00']],
    ['negative after dollar', 'Adjustment $-45.00 applied', ['$-45.00']],
    ['leading decimal dollar', 'Rounding $.50 credit', ['$.50']],
    ['more than two decimals', 'Rate $15.125 per unit', ['$15.125']],
    ['parentheses negative dollar', 'Reversal ($45.00) posted', ['($45.00)']],
    ['dollar with parenthesized amount', 'Reversal $(45.00) posted', ['$(45.00)']],
    ['USD suffix', 'Total 45.67 USD settled', ['45.67 USD']],
    ['USD prefix', 'Total USD 45.67 settled', ['USD 45.67']],
    ['USD with 3 decimals', 'Adjustment USD 12.345 applied', ['USD 12.345']],
    ['parentheses negative USD', 'Credit (45.67 USD) and (USD 10.25)', ['(45.67 USD)', '(USD 10.25)']],
    ['US$ prefix', 'Paid US$1,234.56 today', ['US$1,234.56']],
  ])('matches %s in free text', (_name, input, expectedMoney) => {
    const moneyParts = splitCurrencySegments(input).filter((s) => s.isMoney).map((s) => s.text);
    expect(moneyParts).toEqual(expectedMoney);
  });

  it.each([
    'Includes recorded payroll adjustments.',
    'Paid Nov 20, 2026 for 2026-11-01 to 2026-11-14',
    '36.5 hrs worked (38.5 hours total)',
    'Check #2187 delivered on 11/20/2026',
    'Social Security (6.2%) and Medicare (1.45%)',
    'W-4 4c withholding and 2025 W-2GU',
  ])('does not mask non-money text: %s', (input) => {
    const segments = splitCurrencySegments(input);
    expect(segments).toEqual([{ text: input, isMoney: false }]);
  });

  it('keeps only the hours comparison when hideMoney is true', () => {
    const page = parseStatementPage({ statements: STATEMENTS_2026, years: [2026], next_page: null });
    const [latest, earlier] = page.statements;

    expect(comparisonLine(latest, page.statements, { hideMoney: true }))
      .toBe('You worked 3.5 fewer hours than Nov 6.');
    expect(comparisonLine({ ...latest, totalHours: '45.00' }, page.statements, { hideMoney: true }))
      .toBe('You worked 3 more hours than Nov 6.');
    expect(comparisonLine({ ...latest, totalHours: '42.00' }, page.statements, { hideMoney: true }))
      .toBe('Same hours as Nov 6.');
    // Salaried / missing hours: hides entirely so no money leaks.
    expect(comparisonLine({ ...latest, totalHours: null }, page.statements, { hideMoney: true })).toBeNull();
    expect(comparisonLine(earlier, page.statements, { hideMoney: true })).toBeNull();
  });
});
