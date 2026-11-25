// Fictional data for the employee screens specs. "Coral Kitchen" and everyone
// in it are made up; the shapes follow web/src/employee/contracts.ts.
import type { Page, Route } from '@playwright/test';

export const employeeBaseUrl = `http://127.0.0.1:${process.env.E2E_EMPLOYEE_WEB_PORT || '4175'}`;
export const tenantQuery = 'tenantHost=coral.shimizu-technology.com';

export function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

export const branding = {
  name: 'Coral Kitchen',
  app_name: null,
  logo_url: null,
  primary_color: '#0f7c8c',
  accent_color: '#ffd166',
  main_phone: '(671) 555-0100',
};

export const coralLink = { id: 42, company_name: 'Coral Kitchen', subdomain_slug: 'coral', status: 'active', former_access_until: null };

export const context = {
  first_name: 'Tala',
  status: 'active',
  former_access_until: null,
  next_payday: null as string | null,
  w2_delivery: 'mailed',
  features: { stubs: true, tax_forms: true, profile_requests: true },
};

function check(id: number, payDate: string, start: string, end: string, net: string, gross: string, hours: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    pay_period: { start_date: start, end_date: end, pay_date: payDate, run_purpose: 'regular' },
    check_date: payDate,
    gross_pay: gross,
    net_pay: net,
    total_hours: hours,
    payment: { method: 'direct_deposit', status: 'pending', issued_on: null, check_number_last4: null },
    pdf_available: true,
    ...extra,
  };
}

export const statements2026 = [
  check(906, '2026-11-20', '2026-11-01', '2026-11-14', '534.18', '612.50', '38.50'),
  check(905, '2026-11-06', '2026-10-18', '2026-10-31', '570.63', '651.00', '42.00'),
  check(904, '2026-10-23', '2026-10-04', '2026-10-17', '552.40', '630.00', '40.00', { payment: { method: 'paper_check', status: 'issued', issued_on: '2026-10-23', check_number_last4: '2187' } }),
  check(903, '2026-10-09', '2026-09-20', '2026-10-03', '552.40', '630.00', '40.00'),
  check(902, '2026-09-25', '2026-09-06', '2026-09-19', '489.77', '558.00', '36.00', { corrected: true }),
  { id: 'qb_31', source: 'quickbooks', pay_date: '2026-08-28', period_start: '2026-08-09', period_end: '2026-08-22', gross_pay: '615.00', net_pay: '540.02', hours_total: '41.00', original_pdf: true },
  { id: 'qb_30', source: 'quickbooks', pay_date: '2026-08-14', period_start: '2026-07-26', period_end: '2026-08-08', gross_pay: '600.00', net_pay: '527.70', hours_total: '40.00', original_pdf: false },
];

export const statements2025 = [
  check(801, '2025-12-19', '2025-11-30', '2025-12-13', '498.11', '570.00', '38.00'),
];

export function detailFor(summary: Record<string, unknown>) {
  const quickbooks = summary.source === 'quickbooks';
  return {
    ...summary,
    earnings: quickbooks ? [] : [
      { label: 'Regular', hours: '36.00', rate: '15.00', pay_basis: 'hourly', amount: '540.00', ytd: '24300.00', kind: 'regular' },
      { label: 'Overtime', hours: '2.50', rate: '22.50', pay_basis: 'hourly', amount: '56.25', ytd: '900.00', kind: 'overtime' },
      { label: 'Tips', hours: null, rate: null, pay_basis: null, amount: '16.25', ytd: '1200.00', kind: 'tips' },
    ],
    taxes: [
      { label: 'Federal/Guam Income Tax', amount: '24.50', ytd: '1100.00' },
      { label: 'Social Security (6.2%)', amount: '37.98', ytd: '1580.00' },
      { label: 'Medicare (1.45%)', amount: '8.88', ytd: '370.00' },
    ],
    deductions: quickbooks ? [] : [{ label: 'Uniform', amount: '6.96', ytd: '120.00' }],
    other_pay: [],
    ytd: { gross: '26400.00', net: '23230.00' },
    ...(quickbooks ? { adjustment_note: null } : {}),
  };
}

export const profile = {
  legal_name: 'Tala Mendiola Reyes',
  email: 'tala.reyes@example.com',
  email_verified: true,
  phone: '6715550142',
  phone_confirmed: true,
  address: { address_line1: '100 Example Rd', address_line2: 'Unit 4', city: 'Tamuning', state: 'GU', zip: '96913' },
  payment_method: 'direct_deposit',
  emergency_contacts: [{ id: 1, name: 'Ana Reyes', relationship: 'Sister', phone: '6715550199' }],
  address_request: null as null | Record<string, unknown>,
  other_request_pending: false,
};

export const helpContacts = [
  { name: 'Rina Calvo', role: 'General manager', phone: '(671) 555-0110', email: 'rina@example.com', text_ok: true },
  { name: 'Joe Santos', role: 'Shift lead', phone: '(671) 555-0111', email: null, text_ok: false },
];

export const PDF_BYTES = '%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n';

export const REVERIFY = { clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level: 'first_factor', afterMinutes: 10 } } } };

export interface EmployeeMock {
  branding?: Record<string, unknown> | null;
  links?: unknown;
  context?: Record<string, unknown>;
  statements?: (year: string | null) => unknown[];
  profile?: Record<string, unknown>;
  helpContacts?: unknown[];
  taxForms?: unknown[];
  activation?: (body: Record<string, unknown>) => { status: number; body?: unknown };
  claim?: (body: Record<string, unknown>) => { status: number; body?: unknown };
  reactivate?: (body: Record<string, unknown>) => { status: number; body?: unknown };
  /** Pages of one year's checks, for "Show more". */
  pages?: (year: string | null, page: number) => { statements: unknown[]; next_page: number | null } | null;
}

export interface EmployeeMockLog {
  requests: { method: string; path: string; headers: Record<string, string>; body: unknown }[];
  profile: Record<string, unknown>;
}

/** Mocks branding and every /api/v1/employee route. Changes behind step-up need the preview's verified token. */
export async function mockEmployeeApi(page: Page, mock: EmployeeMock = {}): Promise<EmployeeMockLog> {
  const log: EmployeeMockLog = { requests: [], profile: structuredClone(mock.profile ?? profile) };
  let nextContactId = 50;

  await page.route('**/api/v1/public/tenant_branding**', (route) => (mock.branding === null ? route.fulfill({ status: 404 }) : json(route, mock.branding ?? branding)));
  await page.route('**/api/v1/auth/me', (route) => json(route, { roles: { employee_links_count: 1 } }));
  await page.route('**/api/v1/employee/**', async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace(/^.*\/api\/v1/, '');
    const method = request.method();
    const body = request.postData() ? JSON.parse(request.postData()!) : null;
    log.requests.push({ method, path, headers: request.headers(), body });
    const verified = request.headers().authorization === 'Bearer dev-preview-token-verified';
    const needsStepUp = method !== 'GET' && path !== '/employee/activation';
    // Like EmployeeLinkCheckParams: the invite check is read from the body only.
    if (['/employee/activation', '/employee/links/claim', '/employee/links/reactivate'].includes(path) && ['token', 'code', 'date_of_birth', 'ssn_last4'].some((field) => url.searchParams.has(field))) {
      return json(route, { error: 'Invalid activation request' }, 400);
    }
    if (needsStepUp && !verified) return json(route, REVERIFY, 403);

    if (path === '/employee/links') return json(route, mock.links ?? { links: [coralLink] });
    if (path === '/employee/context') return json(route, mock.context ?? context);
    if (path === '/employee/statements') {
      const year = url.searchParams.get('year');
      const paged = mock.pages?.(year, Number(url.searchParams.get('page')) || 1);
      if (paged) return json(route, { ...paged, years: [2026, 2025] });
      const rows = mock.statements ? mock.statements(year) : year === '2025' ? statements2025 : statements2026;
      return json(route, { statements: rows, years: [2026, 2025], next_page: null });
    }
    const pdf = path.match(/^\/employee\/(?:statements|tax_forms)\/[\w-]+\/pdf$/);
    if (pdf) return route.fulfill({ status: 200, contentType: 'application/pdf', headers: { 'Cache-Control': 'no-store' }, body: PDF_BYTES });
    const statement = path.match(/^\/employee\/statements\/([\w-]+)$/);
    if (statement) {
      const all = [...statements2026, ...statements2025, ...(mock.statements ? mock.statements(null) : [])] as Record<string, unknown>[];
      const found = all.find((row) => String(row.id) === statement[1]);
      return found ? json(route, detailFor(found)) : route.fulfill({ status: 404 });
    }
    if (path === '/employee/tax_forms') return json(route, { tax_forms: mock.taxForms ?? [{ id: 12, tax_year: 2025, kind: 'w2gu', status: 'posted', corrected: false }] });
    if (path === '/employee/help') return json(route, { help_contacts: mock.helpContacts ?? helpContacts });
    if (path === '/employee/profile') return json(route, log.profile);
    if (path === '/employee/profile/phone') {
      log.profile = { ...log.profile, phone: body.phone, phone_confirmed: true };
      return json(route, log.profile);
    }
    if (path === '/employee/profile/email') return json(route, { verification_id: 'ver_1' }, 202);
    if (path === '/employee/profile/email/confirm') {
      log.profile = { ...log.profile, email: 'tala.new@example.com', email_verified: true };
      return json(route, log.profile);
    }
    if (path === '/employee/emergency_contacts' && method === 'POST') {
      const contacts = [...(log.profile.emergency_contacts as unknown[]), { id: nextContactId++, ...body }];
      log.profile = { ...log.profile, emergency_contacts: contacts };
      return json(route, log.profile);
    }
    if (path === '/employee/address_requests' && method === 'POST') {
      log.profile = { ...log.profile, address_request: { id: 8, status: 'pending', requested: body.address, submitted_at: '2026-11-25' } };
      return json(route, log.profile);
    }
    const addressRequest = path.match(/^\/employee\/address_requests\/(\d+)$/);
    if (addressRequest && method === 'DELETE') {
      log.profile = { ...log.profile, address_request: null };
      return json(route, log.profile);
    }
    if (addressRequest && method === 'PATCH') {
      log.profile = { ...log.profile, address_request: { ...(log.profile.address_request as object), requested: body.address } };
      return json(route, log.profile);
    }
    // ActivationsController: one check, both outcomes 200; the sign-up URL lands on /sign-up like Clerk's redirect_url.
    if (path === '/employee/activation') {
      const result = mock.activation?.(body) ?? { status: 200, body: { next: 'sign_up', sign_up_url: '/sign-up?__clerk_ticket=preview', message: null } };
      return json(route, result.body ?? {}, result.status);
    }
    if (path === '/employee/links/claim') {
      const result = mock.claim?.(body) ?? { status: 201, body: { link: coralLink } };
      return json(route, result.body ?? {}, result.status);
    }
    if (path === '/employee/links/reactivate') {
      const result = mock.reactivate?.(body) ?? { status: 201, body: { link: coralLink } };
      return json(route, result.body ?? {}, result.status);
    }
    return route.fulfill({ status: 404 });
  });
  return log;
}

export async function signIn(page: Page): Promise<void> {
  await page.addInitScript(() => sessionStorage.setItem('employee-dev-preview-signed-in', 'true'));
}
