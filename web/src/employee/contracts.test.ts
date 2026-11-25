/** @vitest-environment node */
import { describe, expect, it } from 'vitest';
import {
  parseContext, parseHelpContacts, parseProfile, parseStatementDetail, parseStatementPage, parseStatementSummary, parseTaxForms, signUpUrlFrom,
} from './contracts';
import { addressLines, comparisonLine, formatHours, formatMoney, paymentStatus, taxLabel } from './format';
import { birthDate, normalizeCode } from './signupState';

// EmployeePayStatements::Presenter#summary, as served to AIRE today (fictional values).
const summary = {
  id: 901,
  pay_period: { start_date: '2026-11-01', end_date: '2026-11-14', pay_date: '2026-11-20', run_purpose: 'regular' },
  check_date: '2026-11-20',
  gross_pay: '612.50',
  net_pay: '534.18',
  total_hours: '38.50',
  payment: { method: 'direct_deposit', status: 'pending', issued_on: null, check_number_last4: null },
  has_source_entries: false,
};

describe('employee API contracts', () => {
  it('reads an empty context as everything off', () => {
    expect(parseContext(null)).toEqual({
      firstName: null, status: 'active', formerAccessUntil: null, nextPayday: null, w2Delivery: null,
      features: { stubs: false, taxForms: false, profileRequests: false, deliveryConsent: false },
    });
  });

  it('reads the served context shape', () => {
    const info = parseContext({
      first_name: 'Tala', status: 'former', former_access_until: '2028-03-01', next_payday: '2026-12-04', w2_delivery: 'handed_out',
      features: { stubs: true, tax_forms: true, profile_requests: false },
    });
    expect(info).toMatchObject({ firstName: 'Tala', status: 'former', w2Delivery: 'handed_out', features: { stubs: true, taxForms: true, profileRequests: false } });
    expect(parseContext({ w2_delivery: 'carrier pigeon' }).w2Delivery).toBeNull();
  });

  it('reads the AIRE presenter summary and QuickBooks rows into one list', () => {
    const page = parseStatementPage({
      statements: [
        summary,
        { id: 'qb_77', source: 'quickbooks', pay_date: '2026-08-14', period_start: '2026-08-01', period_end: '2026-08-14', gross_pay: 600, net_pay: '520.00', hours_total: '80.00', original_pdf: true },
        { id: 'bad id!', check_date: '2026-01-01' },
        { id: 5 },
      ],
      years: [2026, 2025, 'x'],
      next_page: 2,
    });
    expect(page.years).toEqual([2026, 2025]);
    expect(page.nextPage).toBe(2);
    expect(page.statements).toHaveLength(2);
    expect(page.statements[0]).toMatchObject({ id: '901', source: 'payroll', payDate: '2026-11-20', runPurpose: 'regular', netPay: '534.18', totalHours: '38.50', pdfAvailable: true, originalPdf: false });
    expect(page.statements[1]).toMatchObject({ id: 'qb_77', source: 'quickbooks', payDate: '2026-08-14', grossPay: '600.00', totalHours: '80.00', pdfAvailable: false, originalPdf: true });
  });

  it('reads the AIRE presenter detail', () => {
    const detail = parseStatementDetail({
      ...summary,
      earnings: [{ label: 'Regular', hours: '38.50', rate: '15.00', pay_basis: 'hourly', amount: '577.50', ytd: '12000.00', kind: 'regular' }, { label: '', amount: '1' }],
      taxes: [{ label: 'Federal/Guam Income Tax', amount: '20.00', ytd: '400.00' }],
      deductions: [],
      other_pay: [],
      ytd: { gross: '13000.00', net: '11000.00' },
    });
    expect(detail?.earnings).toEqual([{ label: 'Regular', hours: '38.50', rate: '15.00', amount: '577.50', ytd: '12000.00', kind: 'regular' }]);
    expect(detail?.ytdNet).toBe('11000.00');
    expect(detail?.taxes).toEqual([{ label: 'Federal/Guam Income Tax', amount: '20.00', ytd: '400.00', kind: null, displayLabel: null }]);
    expect(detail?.earlierVersions).toEqual([]);
    expect(parseStatementDetail({})).toBeNull();
  });

  it('reads tax kinds and earlier versions from the employee presenter', () => {
    const detail = parseStatementDetail({
      ...summary,
      taxes: [
        { label: 'Federal/Guam Income Tax', amount: '20.00', ytd: null, kind: 'guam_income_tax', display_label: 'Guam income tax' },
        { label: 'Territory surcharge', amount: '1.00', ytd: null, kind: 'something_new', display_label: 'Territory surcharge' },
      ],
      earlier_versions: [
        { id: '880', status: 'replaced', posted_at: '2026-11-20T08:00:00Z', payment_line: 'Check #4012' },
        { id: '881', status: 'withdrawn', posted_at: '2026-11-21T08:00:00Z', payment_line: null },
        { id: 'bad id!', status: 'replaced' },
        { id: '879', status: 'replaced', posted_at: 'not a time' },
      ],
    });
    expect(detail?.taxes.map((tax) => [tax.kind, tax.displayLabel])).toEqual([
      ['guam_income_tax', 'Guam income tax'], [null, 'Territory surcharge'],
    ]);
    expect(detail?.earlierVersions).toEqual([
      { id: '880', status: 'replaced', postedAt: '2026-11-20T08:00:00Z', paymentLine: 'Check #4012' },
      { id: '879', status: 'replaced', postedAt: null, paymentLine: null },
    ]);
  });

  it('keeps a QuickBooks check\'s payment status unknown instead of pending', () => {
    const row = parseStatementSummary({ id: 'qb-77', source: 'quickbooks', pay_date: '2026-08-14',
      payment: { method: 'paper_check', status: null, issued_on: null, check_number_last4: '1088' } });
    expect(row?.payment).toEqual({ method: 'paper_check', status: null, issuedOn: null, checkNumberLast4: '1088' });
    expect(row && paymentStatus(row.payment)).toBeNull();
  });

  it('reads tax forms, Help contacts and the profile defensively', () => {
    expect(parseTaxForms({ tax_forms: [
      { id: '5', tax_year: 2027, kind: 'w2gu', status: 'posted', corrected: true, posted_at: '2028-01-20T00:00:00Z', pdf_available: true, available_through: '2028-10-15' },
      { id: 3, tax_year: 2026, kind: 'w2gu', status: 'withdrawn', pdf_available: false },
      { id: 4, tax_year: 2026, kind: '1099', status: 'posted' },
      { id: 6, tax_year: 2026, kind: 'w2gu', status: 'replaced' },
      { id: 7, tax_year: 2026, status: 'posted' },
    ] }))
      .toEqual([{ id: '5', taxYear: 2027, status: 'posted', corrected: true }, { id: '3', taxYear: 2026, status: 'withdrawn', corrected: false }]);
    expect(parseHelpContacts({ help_contacts: [{ name: 'Rina Calvo', role: 'Manager', phone: '671-555-0100', email: null, text_ok: true }, { name: 'No way to reach', phone: null, email: null }] }))
      .toEqual([{ name: 'Rina Calvo', role: 'Manager', phone: '671-555-0100', email: null, textOk: true }]);
    // Phones and emails become tel:, sms: and mailto: links, so anything else is dropped first.
    expect(parseHelpContacts({ help_contacts: [
      { name: 'Joe', phone: '671-555-0111?body=hi', email: 'joe@example.com?cc=x@example.com', text_ok: true },
      { name: 'Ana', phone: '12', email: 'ana@example.com', text_ok: true },
      { name: 'Lee', phone: '+1 (671) 555-0112', email: 'lee@@example.com' },
    ] })).toEqual([
      { name: 'Ana', role: null, phone: null, email: 'ana@example.com', textOk: false },
      { name: 'Lee', role: null, phone: '+1 (671) 555-0112', email: null, textOk: false },
    ]);
    const profile = parseProfile({
      email: 'tala@example.com', email_verified: true, phone: '6715550100',
      address: { address_line1: '100 Example Rd', city: 'Tamuning', state: 'GU', zip: '96913' },
      address_request: { id: 8, status: 'pending', requested: { address_line1: '200 Sample Ave', city: 'Hagåtña', state: 'GU', zip: '96910' }, submitted_at: '2026-11-21T10:00:00Z' },
      emergency_contacts: [{ id: 1, name: 'Ana Reyes', relationship: 'Sister', phone: '671-555-0199' }],
    });
    expect(profile.emailVerified).toBe(true);
    expect(profile.phoneConfirmed).toBe(false);
    expect(profile.addressRequest).toMatchObject({ id: '8', status: 'pending', submittedAt: '2026-11-21', requested: { line1: '200 Sample Ave' } });
    expect(profile.emergencyContacts).toHaveLength(1);
  });

  it('drops SSN fragments from profile data', () => {
    expect(parseProfile({ legal_name: 'Example Worker', ssn_last4: '0001' })).not.toHaveProperty('ssnLast4');
  });

  it('follows only https or same-site sign-up URLs', () => {
    expect(signUpUrlFrom({ sign_up_url: 'https://accounts.example.test/x' }, 'https://app.example.test')).toBe('https://accounts.example.test/x');
    expect(signUpUrlFrom({ sign_up_url: '/sign-up?__clerk_ticket=t' }, 'http://127.0.0.1:4175')).toBe('http://127.0.0.1:4175/sign-up?__clerk_ticket=t');
    expect(signUpUrlFrom({ sign_up_url: 'data:text/html,hi' }, 'https://app.example.test')).toBeNull();
  });
});

describe('employee formatting', () => {
  it('formats money and hours', () => {
    expect(formatMoney('1234.5')).toBe('$1,234.50');
    expect(formatMoney(null)).toBeNull();
    expect(formatHours('38.50')).toBe('38.5');
  });

  it('never calls Guam income tax "Federal"', () => {
    expect(taxLabel('Federal/Guam Income Tax')).toEqual({ label: 'Guam income tax', term: 'Withholding' });
    expect(taxLabel('Additional Withholding (W-4 4c)').label).not.toMatch(/federal/i);
    expect(taxLabel('Federal something else').label).toBe('something else');
    expect(taxLabel('Social Security (6.2%)')).toEqual({ label: 'Social Security', term: 'FICA' });
  });

  it('shows only payment states that are certain', () => {
    expect(paymentStatus({ method: 'direct_deposit', status: 'pending', issuedOn: null, checkNumberLast4: null })).toBeNull();
    expect(paymentStatus({ method: 'direct_deposit', status: 'prepared', issuedOn: null, checkNumberLast4: null })).toBeNull();
    expect(paymentStatus({ method: 'paper_check', status: 'issued', issuedOn: null, checkNumberLast4: '1234' })?.label).toBe('Check delivered');
    expect(paymentStatus({ method: 'paper_check', status: 'voided', issuedOn: null, checkNumberLast4: '1234' })?.tone).toBe('bad');
  });

  it('compares with the previous regular check, and hides when it can\'t', () => {
    const page = parseStatementPage({ statements: [
      { ...summary, id: 3, check_date: '2026-11-20', net_pay: '534.18', total_hours: '38.50' },
      { ...summary, id: 2, check_date: '2026-11-13', pay_period: { ...summary.pay_period, run_purpose: 'bonus' }, net_pay: '100.00' },
      { ...summary, id: 1, check_date: '2026-11-06', net_pay: '570.63', total_hours: '42.00' },
    ] });
    const [latest, bonus, first] = page.statements;
    expect(comparisonLine(latest, page.statements)).toBe('$36.45 less than Nov 6. You worked 3.5 fewer hours.');
    expect(comparisonLine(bonus, page.statements)).toBeNull();
    expect(comparisonLine(first, page.statements)).toBeNull();
    expect(comparisonLine({ ...latest, totalHours: null }, page.statements)).toBe('$36.45 less than Nov 6.');
  });

  it('uses the API\'s previous check, even from another page, and hides when the API says there is none', () => {
    const page = parseStatementPage({ statements: [
      { ...summary, id: 3, check_date: '2026-11-20', net_pay: '534.18', total_hours: '38.50',
        previous: { id: '1', pay_date: '2026-11-06', check_date: '2026-11-06', net_pay: '570.63', total_hours: '42.00' } },
      { ...summary, id: 1, check_date: '2026-11-06', net_pay: '570.63', total_hours: '42.00', previous: null },
    ] });
    const [latest, first] = page.statements;
    expect(latest.previous).toEqual({ id: '1', payDate: '2026-11-06', netPay: '570.63', totalHours: '42.00' });
    expect(comparisonLine(latest, [latest])).toBe('$36.45 less than Nov 6. You worked 3.5 fewer hours.');
    expect(comparisonLine(first, [first, { ...latest, id: '0' }])).toBeNull();
    expect(parseStatementSummary({ ...summary, previous: { id: 'bad id!', pay_date: '2026-11-06' } })?.previous).toBeNull();
  });

  it('writes an address on as few lines as it needs', () => {
    expect(addressLines({ line1: '100 Example Rd', line2: '', city: 'Tamuning', state: 'GU', zip: '96913' })).toEqual(['100 Example Rd', 'Tamuning, GU 96913']);
  });
});

describe('sign-up helpers', () => {
  it('accepts codes typed with spaces, dashes and any case', () => {
    expect(normalizeCode('abcde-fghjk')).toBe('ABCDEFGHJK');
    expect(normalizeCode(' AbC de FGH jk ')).toBe('ABCDEFGHJK');
  });

  it('accepts only real birth dates', () => {
    const now = new Date(2026, 10, 25);
    expect(birthDate({ month: '4', day: '7', year: '1990' }, now)).toBe('1990-04-07');
    expect(birthDate({ month: '2', day: '30', year: '1990' }, now)).toBeNull();
    expect(birthDate({ month: '', day: '7', year: '1990' }, now)).toBeNull();
    expect(birthDate({ month: '1', day: '1', year: '2025' }, now)).toBeNull();
  });
});
