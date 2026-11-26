// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';
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
 * Scans visible text, aria-label, title, aria-valuetext, alt, accessible names,
 * and inline filter styles to verify zero money amounts leak while masked and
 * CSS blur is never used.
 */
function expectMaskedDomClean(root: HTMLElement, extraForbidden: string[] = []): void {
  const forbidden = [...FORBIDDEN_AMOUNTS, ...extraForbidden];
  const text = root.textContent ?? '';
  expect(text).not.toMatch(/\$\s*-?\d/);
  for (const figure of forbidden) {
    expect(text, `visible text leaked ${figure}`).not.toContain(figure);
  }

  for (const node of root.querySelectorAll<HTMLElement>('*')) {
    for (const attr of ['aria-label', 'title', 'aria-valuetext', 'alt', 'aria-description']) {
      const value = node.getAttribute(attr);
      if (!value) continue;
      expect(value, `${attr} leaked currency`).not.toMatch(/\$\s*-?\d/);
      for (const figure of forbidden) {
        expect(value, `${attr} leaked ${figure}`).not.toContain(figure);
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
  it('masks Home by default while keeping hours, dates and payment method visible', async () => {
    const { container } = render(<EmployeeApp />);
    const latest = await screen.findByRole('region', { name: 'Latest pay' });
    await within(latest).findByRole('link', { name: 'View pay stub' });

    const toggle = within(latest).getByRole('button', { name: 'Show amounts' });
    expect(toggle.getAttribute('aria-pressed')).toBeNull();
    expect(latest.textContent).toContain('$•••');
    expect(within(latest).getAllByText('Amount hidden').length).toBeGreaterThan(0);

    // Non-money details stay visible.
    expect(latest.textContent).toContain('Paid Nov 20, 2026');
    expect(latest.textContent).toContain('Check #2187');
    expect(latest.textContent).toContain('38.5 hours');
    // Comparison line names an amount, so it hides while masked.
    expect(latest.textContent).not.toContain('less than');

    // Every screen region (including Recent pay and This year so far) leaks no amounts.
    expectMaskedDomClean(container);

    // Tapping Show amounts reveals amounts and the comparison line.
    await userEvent.click(toggle);
    expect(within(latest).getByRole('button', { name: 'Hide amounts' }).getAttribute('aria-pressed')).toBeNull();
    expect(latest.textContent).toContain('$534.18');
    expect(latest.textContent).toContain('$36.45 less than Nov 6');
  });

  it('masks the Pay list by default while keeping dates and hours visible', async () => {
    window.history.pushState({}, '', '/pay');
    const { container } = render(<EmployeeApp />);
    const list = await screen.findByRole('list', { name: 'Paychecks' });
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);

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

    // Dates, payment method and hours remain visible; rates are masked with dots.
    expect(stub.textContent).toContain('Nov 1 – 14, 2026');
    expect(stub.textContent).toContain('Paid Nov 20, 2026');
    expect(stub.textContent).toContain('Check #2187');
    expect(stub.textContent).toContain('38.5 hours');
    expect(stub.textContent).toContain('36 hrs × $•••');
    expect(stub.textContent).toContain('2.5 hrs × $•••');
    expect(within(stub).getAllByText('Amount hidden').length).toBeGreaterThan(0);

    // Every PDF button warns that it shows amounts while masked.
    expect(within(stub).getByRole('button', { name: 'Download PDF (shows amounts)' })).toBeTruthy();
    await userEvent.click(within(stub).getByText('Corrected — see the original'));
    expect(within(stub).getByRole('button', { name: 'Download earlier PDF (shows amounts)' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download original PDF (shows amounts)' })).toBeTruthy();

    expectMaskedDomClean(container);

    // Unmasking reveals rates, amounts, comparison and base PDF labels.
    await userEvent.click(screen.getByRole('button', { name: 'Show amounts' }));
    expect(stub.textContent).toContain('36 hrs × $15.00');
    expect(stub.textContent).toContain('2.5 hrs × $22.50');
    expect(stub.textContent).toContain('$534.18');
    expect(stub.textContent).toContain('$23,230.00');
    expect(within(stub).getByRole('button', { name: 'Download PDF' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download earlier PDF' })).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'Download original PDF' })).toBeTruthy();
  });

  it('keeps stub notes free of leaked amounts on QuickBooks stubs and masks any dollar figure in a note', async () => {
    window.history.pushState({}, '', '/pay/qb_31');
    const first = render(<EmployeeApp />);
    const stub = await screen.findByRole('article');
    expect(within(stub).getByText('Includes recorded payroll adjustments.')).toBeTruthy();
    expect(within(stub).getByRole('button', { name: 'View original stub PDF (shows amounts)' })).toBeTruthy();
    expectMaskedDomClean(first.container);
    first.unmount();

    // Defense in depth: even if a future API note contained a currency figure, it is masked while hidden.
    vi.stubGlobal('fetch', mockEmployeeRoutes({
      '/employee/statements/qb_31': () => Response.json({
        ...DETAIL_QB,
        adjustment_note: 'Adjusted by $45.67 for holiday pay.',
        note: 'Adjusted by $45.67 for holiday pay.',
      }),
    }));
    const second = render(<EmployeeApp />);
    const stubWithCurrencyNote = await screen.findByRole('article');
    expect(stubWithCurrencyNote.textContent).toContain('Adjusted by $•••');
    expectMaskedDomClean(second.container, ['45.67']);
  });

  it('masks Tax forms PDF download label while masked, and exposes no money on Tax forms, My info or Help', async () => {
    window.history.pushState({}, '', '/taxes');
    const taxes = render(<EmployeeApp />);
    expect(await screen.findByRole('button', { name: 'Download W-2GU PDF (shows amounts)' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Show amounts' }).getAttribute('aria-pressed')).toBeNull();
    expectMaskedDomClean(taxes.container);
    taxes.unmount();

    window.history.pushState({}, '', '/my-info');
    const myInfo = render(<EmployeeApp />);
    expect(await screen.findByText('Direct deposit')).toBeTruthy();
    expectMaskedDomClean(myInfo.container);
    myInfo.unmount();

    window.history.pushState({}, '', '/help');
    const help = render(<EmployeeApp />);
    expect(await screen.findByText('Rina Calvo')).toBeTruthy();
    expectMaskedDomClean(help.container);
  });

  it('shows the one-time explainer once per device and never repeats it on subsequent loads', async () => {
    const first = render(<EmployeeApp />);
    expect(await screen.findByRole('button', { name: 'Show amounts' })).toBeTruthy();
    const explainerText = 'Amounts stay hidden on this device until you tap Show amounts.';
    const explainer = screen.getByText(explainerText);
    expect(explainer.getAttribute('role')).toBe('status');
    expect(localStorage.getItem(HIDE_AMOUNTS_EXPLAINED_KEY)).toBe('true');
    first.unmount();

    // Second page load on the same device: still masked, no explainer repeat.
    const second = render(<EmployeeApp />);
    const showButton = await screen.findByRole('button', { name: 'Show amounts' });
    expect(screen.queryByText(explainerText)).toBeNull();

    // Tapping Show then Hide also does not re-show the one-time explainer.
    await userEvent.click(showButton);
    await userEvent.click(screen.getByRole('button', { name: 'Hide amounts' }));
    expect(screen.queryByText(explainerText)).toBeNull();
    second.unmount();
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
      expect(within(latestReloaded).getByRole('button', { name: 'Show amounts' })).toBeTruthy();
      expectMaskedDomClean(second.container);
    } finally {
      if (originalDescriptor) Object.defineProperty(window, 'localStorage', originalDescriptor);
    }
  });
});
