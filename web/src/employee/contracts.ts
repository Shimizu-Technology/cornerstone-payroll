// Every shape the employee app reads from or sends to /api/v1/employee/*, in
// one file, so wiring the real endpoints is a small diff.
//
// Each section names the controller that serves it. Each parser accepts what
// the API sends, drops entries it can't use, and never throws, so a field the
// API adds or renames later degrades to "hidden" instead of a broken screen.

/** Money arrives as a decimal string ("1234.50"), as EmployeePayStatements::Presenter#money writes it. */
export type Money = string;

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

function bool(value: unknown): boolean {
  return value === true;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}/;

/** The calendar day of an ISO date or datetime ("2027-06-30T23:59:59Z" -> "2027-06-30"), or null. */
export function isoDate(value: unknown): string | null {
  return typeof value === 'string' && ISO_DATE.test(value) ? value.slice(0, 10) : null;
}

const GUAM_DAY = new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit' });

/** The Guam calendar day (YYYY-MM-DD) of an instant: every client is on Guam time. */
export function guamDay(at: Date): string {
  const parts = Object.fromEntries(GUAM_DAY.formatToParts(at).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

/**
 * The Guam day of an API instant, such as former_access_until
 * ("2028-03-01T23:59:59+10:00", end of that Guam day) or a request's
 * submitted_at (UTC); a plain date passes through.
 */
export function accessDay(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  if (!ISO_DATE.test(value)) return null;
  const at = new Date(value);
  return Number.isNaN(at.getTime()) ? null : guamDay(at);
}

const DECIMAL = /^-?\d+(?:\.\d+)?$/;

function money(value: unknown): Money | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value.toFixed(2);
  return typeof value === 'string' && DECIMAL.test(value.trim()) ? value.trim() : null;
}

/** Ids are opaque strings: payroll items and QuickBooks checks share one list. */
function id(value: unknown): string | null {
  if (typeof value === 'number') return Number.isSafeInteger(value) && value > 0 ? String(value) : null;
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value) ? value : null;
}

function list(value: unknown, key: string): unknown[] {
  if (Array.isArray(value)) return value;
  const items = record(value)?.[key];
  return Array.isArray(items) ? items : [];
}

function oneOf<T extends string>(value: unknown, options: readonly T[]): T | null {
  return typeof value === 'string' && (options as readonly string[]).includes(value) ? value as T : null;
}

// ---------- GET /employee/context ----------
// Served (ContextController, M4-4c):
// { first_name, status: "active" | "former", former_access_until: "2028-03-01" | null
//   (the last Guam day of access), next_payday: "2026-12-04" | null,
//   w2_delivery: "mailed" | "handed_out" | null (the company's setting, M4-5),
//   features: { stubs, tax_forms, profile_requests } }
// next_payday is set only from the company's next regular run when its date
// is settled (committed, or created on a confirmed schedule), never for a
// former employee (§8a).

export type W2Delivery = 'mailed' | 'handed_out';

export interface EmployeeContextInfo {
  firstName: string | null;
  status: 'active' | 'former';
  formerAccessUntil: string | null;
  /** Shown only when the API knows it from a real upcoming pay period or a confirmed schedule (§8a). */
  nextPayday: string | null;
  /** Per-company W-2 setting (§8a). Null when the company hasn't set it. */
  w2Delivery: W2Delivery | null;
  /** True only for a demo company (D-3). */
  demo?: boolean;
  /** The company's employee_portal.features switches. A missing switch counts as off. */
  features: { stubs: boolean; taxForms: boolean; profileRequests: boolean; deliveryConsent: boolean };
}

export function parseContext(data: unknown): EmployeeContextInfo {
  const body = record(data) ?? {};
  const features = record(body.features) ?? {};
  return {
    firstName: text(body.first_name),
    status: body.status === 'former' ? 'former' : 'active',
    formerAccessUntil: accessDay(body.former_access_until),
    nextPayday: isoDate(body.next_payday),
    w2Delivery: oneOf(body.w2_delivery, ['mailed', 'handed_out'] as const),
    demo: bool(body.demo),
    features: {
      stubs: bool(features.stubs),
      taxForms: bool(features.tax_forms),
      profileRequests: bool(features.profile_requests),
      deliveryConsent: bool(features.delivery_consent),
    },
  };
}

// ---------- GET /employee/statements?year=&page= ----------
// Served (StatementsController, EmployeeStatements::Presenter, M4-4c):
// { statements: [...], years: [2026, 2025], next_page: 2 | null }, 20 a page,
// newest first. Payroll rows are EmployeePayStatements::Presenter#summary
// (what AIRE reads) plus source: "payroll", pdf_available, original_pdf,
// corrected, posted_at and previous; their id is the posted stub's id ("123").
// QuickBooks rows ("From QuickBooks records") have id "qb-123", source
// "quickbooks", payment.status null (no payment evidence), adjustment_note,
// and pdf_available/original_pdf when Cornerstone's original stub was posted.
// previous is { id, pay_date, check_date, net_pay, total_hours } for a regular
// check whose previous regular check is known, even on another page; null
// when there is none to compare with.

export type StatementSource = 'payroll' | 'quickbooks';
export type PaymentMethod = 'direct_deposit' | 'paper_check';
export type PaymentStatus = 'issued' | 'prepared' | 'pending' | 'voided';

export interface StatementPayment {
  method: PaymentMethod | null;
  /** null: no payment evidence is recorded (QuickBooks checks), or an unknown value. */
  status: PaymentStatus | null;
  issuedOn: string | null;
  checkNumberLast4: string | null;
}

/** The regular check before this one, for "vs last check". */
export interface PreviousCheck {
  id: string;
  payDate: string;
  netPay: Money | null;
  totalHours: string | null;
}

export interface StatementSummary {
  id: string;
  source: StatementSource;
  /** The date printed on the check: its check date, else the pay period's pay date. */
  payDate: string;
  /** The year the API lists the check under: its pay period's pay date (W-2GU's year). */
  taxYear: number;
  periodStart: string | null;
  periodEnd: string | null;
  /** "regular", "bonus", "adjustment"…: only regular checks are compared with the one before. */
  runPurpose: string | null;
  grossPay: Money | null;
  netPay: Money | null;
  totalHours: string | null;
  payment: StatementPayment;
  withdrawn?: boolean;
  notice?: string | null;
  /** A frozen PDF can be downloaded (payroll checks once posted). */
  pdfAvailable: boolean;
  /** QuickBooks checks only: Cornerstone's original stub was posted for this check. */
  originalPdf: boolean;
  /** A corrected revision replaced the first one posted. */
  corrected: boolean;
  /**
   * The API's previous regular check. null: nothing to compare with.
   * undefined: the response didn't say, so the list decides (format.ts).
   */
  previous?: PreviousCheck | null;
}

function parsePrevious(value: unknown): PreviousCheck | null {
  const row = record(value);
  const previousId = id(row?.id);
  const payDate = isoDate(row?.check_date) ?? isoDate(row?.pay_date);
  return row && previousId && payDate
    ? { id: previousId, payDate, netPay: money(row.net_pay), totalHours: money(row.total_hours) } : null;
}

function parsePayment(value: unknown): StatementPayment {
  const payment = record(value) ?? {};
  return {
    method: oneOf(payment.method, ['direct_deposit', 'paper_check'] as const),
    status: oneOf(payment.status, ['issued', 'prepared', 'pending', 'voided'] as const),
    issuedOn: isoDate(payment.issued_on),
    checkNumberLast4: text(payment.check_number_last4),
  };
}

export function parseStatementSummary(value: unknown): StatementSummary | null {
  const row = record(value);
  if (!row) return null;
  const period = record(row.pay_period) ?? {};
  const statementId = id(row.id);
  // QuickBooks rows (EmployeeDocuments::QuickbooksHistory) say pay_date at the top level.
  const payDate = isoDate(row.check_date) ?? isoDate(period.pay_date) ?? isoDate(row.pay_date);
  if (!statementId || !payDate) return null;
  const source = row.source === 'quickbooks' ? 'quickbooks' : 'payroll';
  return {
    id: statementId,
    source,
    payDate,
    taxYear: Number((isoDate(period.pay_date) ?? isoDate(row.pay_date) ?? payDate).slice(0, 4)),
    periodStart: isoDate(period.start_date) ?? isoDate(row.period_start),
    periodEnd: isoDate(period.end_date) ?? isoDate(row.period_end),
    runPurpose: text(period.run_purpose),
    ...(row.status === 'withdrawn' ? { withdrawn: true } : {}),
    ...(typeof row.notice === 'string' ? { notice: row.notice } : {}),
    grossPay: money(row.gross_pay),
    netPay: money(row.net_pay),
    totalHours: money(row.total_hours ?? row.hours_total),
    payment: parsePayment(row.payment),
    pdfAvailable: source === 'payroll' && row.pdf_available !== false,
    originalPdf: source === 'quickbooks' && bool(row.original_pdf),
    corrected: bool(row.corrected),
    ...('previous' in row ? { previous: parsePrevious(row.previous) } : {}),
  };
}

export interface StatementPage {
  statements: StatementSummary[];
  years: number[];
  nextPage: number | null;
}

export function parseStatementPage(data: unknown): StatementPage {
  const body = record(data) ?? {};
  const statements = list(data, 'statements').flatMap((row) => parseStatementSummary(row) ?? []);
  const years = Array.isArray(body.years)
    ? body.years.filter((year): year is number => Number.isInteger(year) && year > 1900 && year < 3000)
    : [];
  const nextPage = Number.isInteger(body.next_page) && (body.next_page as number) > 0 ? body.next_page as number : null;
  return { statements, years, nextPage };
}

// ---------- GET /employee/statements/:id ----------
// Served: the summary above plus EmployeePayStatements::Presenter#detail's
// earnings (label, hours, rate, amount, ytd, kind), taxes (plus kind and
// display_label, e.g. "guam_income_tax" / "Guam income tax"), deductions,
// other_pay, ytd { gross, net }, note, and earlier_versions: the revisions a
// current stub replaced, [{ id, status: "replaced", posted_at, payment_line, corrected }],
// each downloadable as it was issued from /employee/statements/:id/pdf.
// A replaced revision's id opens the current version. QuickBooks rows show
// their imported breakdown, or only adjusted totals with a note when an
// adjustment was recorded; they have no YTD.
//
// GET /employee/statements/:id/pdf: the frozen PDF as posted, Cache-Control: no-store.

export interface EarningLine {
  label: string;
  hours: string | null;
  rate: Money | null;
  amount: Money | null;
  ytd: Money | null;
  /** "regular", "overtime", "tips"… from PayStubGenerator#statement_earning_kind. */
  kind: string | null;
}

export interface AmountLine {
  label: string;
  amount: Money | null;
  ytd: Money | null;
}

export type TaxKind = 'guam_income_tax' | 'additional_guam_income_tax' | 'social_security' | 'medicare' | 'additional_medicare';

export interface TaxLine extends AmountLine {
  /** null for a tax the presenter doesn't name (shown by its printed label). */
  kind: TaxKind | null;
  /** The plain label, e.g. "Guam income tax" for "Federal/Guam Income Tax". */
  displayLabel: string | null;
}

/** A replaced revision, downloadable as it was issued. */
export interface EarlierVersion {
  id: string;
  status: 'replaced';
  corrected: boolean;
  postedAt: string | null;
  paymentLine: string | null;
  ytdChanged: boolean;
}

export interface StatementDetail extends StatementSummary {
  ytdChanged: boolean;
  earnings: EarningLine[];
  taxes: TaxLine[];
  deductions: AmountLine[];
  otherPay: AmountLine[];
  /** Paid by the employer on top of pay, as the PDF prints them; never part of take-home pay. */
  employerContributions: AmountLine[];
  ytdGross: Money | null;
  ytdNet: Money | null;
  /** Set while an earlier paycheck's place in the year-to-date is being reviewed. */
  ytdNote: string | null;
  /** QuickBooks checks with recorded adjustments: "Includes recorded payroll adjustments." */
  note: string | null;
  /** Newest first; empty unless this stub is a corrected revision. */
  earlierVersions: EarlierVersion[];
}

function taxLines(value: unknown): TaxLine[] {
  return (Array.isArray(value) ? value : []).flatMap((item) => {
    const line = record(item);
    const label = text(line?.label);
    return line && label ? [{
      label, amount: money(line.amount), ytd: money(line.ytd),
      kind: oneOf(line.kind, ['guam_income_tax', 'additional_guam_income_tax', 'social_security', 'medicare', 'additional_medicare'] as const),
      displayLabel: text(line.display_label),
    }] : [];
  });
}

function earlierVersions(value: unknown): EarlierVersion[] {
  return (Array.isArray(value) ? value : []).flatMap((item) => {
    const version = record(item);
    const versionId = id(version?.id);
    if (!version || !versionId || version.status !== 'replaced') return [];
    const postedAt = text(version.posted_at);
    return [{
      id: versionId, status: 'replaced' as const,
      postedAt: postedAt && !Number.isNaN(Date.parse(postedAt)) ? postedAt : null,
      paymentLine: text(version.payment_line),
      corrected: bool(version.corrected),
      ytdChanged: bool(version.ytd_changed),
    }];
  });
}

function amountLines(value: unknown): AmountLine[] {
  return (Array.isArray(value) ? value : []).flatMap((item) => {
    const line = record(item);
    const label = text(line?.label);
    return line && label ? [{ label, amount: money(line.amount), ytd: money(line.ytd) }] : [];
  });
}

export function parseStatementDetail(data: unknown): StatementDetail | null {
  const body = record(data);
  const summary = parseStatementSummary(body);
  if (!body || !summary) return null;
  const ytd = record(body.ytd) ?? {};
  const earnings = (Array.isArray(body.earnings) ? body.earnings : []).flatMap((item) => {
    const line = record(item);
    const label = text(line?.label);
    return line && label ? [{ label, hours: money(line.hours), rate: money(line.rate), amount: money(line.amount), ytd: money(line.ytd), kind: text(line.kind) }] : [];
  });
  return {
    ...summary,
    earnings,
    taxes: taxLines(body.taxes),
    deductions: amountLines(body.deductions),
    otherPay: amountLines(body.other_pay),
    employerContributions: amountLines(body.employer_contributions),
    ytdGross: money(ytd.gross),
    ytdNet: money(ytd.net),
    ytdNote: text(body.ytd_note),
    note: text(body.adjustment_note) ?? text(body.note),
    earlierVersions: earlierVersions(body.earlier_versions),
    ytdChanged: bool(body.ytd_changed),
  };
}

// ---------- GET /employee/tax_forms ----------
// Served (TaxFormsController, M4-5): { tax_forms: [{ id, tax_year, kind: "w2gu",
//   status: "posted" | "withdrawn", corrected, posted_at, pdf_available, available_through }] },
// newest year first. "posted" can be downloaded; "withdrawn" means staff pulled
// it and a corrected form is being prepared (no W-2c yet). PDF (frozen,
// no-store): /employee/tax_forms/:id/pdf.

export interface TaxForm {
  id: string;
  taxYear: number;
  status: 'posted' | 'withdrawn';
  corrected: boolean;
}

export function parseTaxForms(data: unknown): TaxForm[] {
  return list(data, 'tax_forms').flatMap((item) => {
    const form = record(item);
    const formId = id(form?.id);
    const year = form?.tax_year;
    if (!form || !formId || !Number.isInteger(year)) return [];
    if (form.kind !== 'w2gu' || (form.status !== 'posted' && form.status !== 'withdrawn')) return [];
    return [{ id: formId, taxYear: year as number, status: form.status, corrected: bool(form.corrected) }];
  });
}

// ---------- GET /employee/job ----------
// Served (JobController, EmployeeProfiles::Job): { job: { employer_name,
// department, role, employee_id, worker_type: "w2" | "1099", pay_frequency,
// pay: { type: "hourly", rates: [{ label, rate }] } | { type: "salary",
// per_period, annual } | { type: "flat_fee", per_period }, start_date,
// payment_method, contact_name } | null }. Null for a former job. Pay is as
// of today; no SSN or bank numbers.

export type PayFrequency = 'weekly' | 'biweekly' | 'semimonthly' | 'monthly';

export interface JobRate {
  /** The job's name on the wage rate ("Server"), or null for a single profile rate. */
  label: string | null;
  rate: Money;
}

export type JobPay =
  | { type: 'hourly'; rates: JobRate[] }
  /** Both null for a salary set each pay period. */
  | { type: 'salary'; perPeriod: Money | null; annual: Money | null }
  | { type: 'flat_fee'; perPeriod: Money | null };

export interface EmployeeJob {
  employerName: string | null;
  department: string | null;
  role: string | null;
  /** The number printed as "Employee ID" on pay stubs. */
  employeeId: string | null;
  workerType: 'w2' | '1099';
  payFrequency: PayFrequency | null;
  pay: JobPay | null;
  startDate: string | null;
  paymentMethod: 'direct_deposit' | 'paper_check' | null;
  /** The first Help contact's name, for "Something wrong? Contact ...". */
  contactName: string | null;
}

function jobPay(value: unknown): JobPay | null {
  const pay = record(value);
  if (pay?.type === 'hourly') {
    const rates = list(pay, 'rates').flatMap((item) => {
      const row = record(item);
      const rate = money(row?.rate);
      return rate ? [{ label: text(row?.label), rate }] : [];
    });
    return rates.length > 0 ? { type: 'hourly', rates } : null;
  }
  if (pay?.type === 'salary') return { type: 'salary', perPeriod: money(pay.per_period), annual: money(pay.annual) };
  if (pay?.type === 'flat_fee') return { type: 'flat_fee', perPeriod: money(pay.per_period) };
  return null;
}

export function parseJob(data: unknown): EmployeeJob | null {
  const job = record(record(data)?.job);
  if (!job) return null;
  return {
    employerName: text(job.employer_name),
    department: text(job.department),
    role: text(job.role),
    employeeId: text(job.employee_id),
    workerType: job.worker_type === '1099' ? '1099' : 'w2',
    payFrequency: oneOf(job.pay_frequency, ['weekly', 'biweekly', 'semimonthly', 'monthly'] as const),
    pay: jobPay(job.pay),
    startDate: isoDate(job.start_date),
    paymentMethod: oneOf(job.payment_method, ['direct_deposit', 'paper_check'] as const),
    contactName: text(job.contact_name),
  };
}

// ---------- GET /employee/help ----------
// Served (HelpController, M4-4c): { help_contacts: [{ name, role, phone, email, text_ok }] },
// each CompanyHelpContact#as_help_json (M4-9a), in the order the client set.
// An empty list means none are set yet. The company's main phone comes from
// the public branding response instead.

export interface HelpContact {
  name: string;
  role: string | null;
  phone: string | null;
  email: string | null;
  textOk: boolean;
}

// Checked before they become tel:, sms: and mailto: links, so a stray value
// can't add a query (?cc=, ?body=) or a second address.
const DIALABLE = /^\+?[\d\s().-]+$/;
const EMAIL_ADDRESS = /^[^\s@<>()[\]\\,;:"?&#%/]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;

function dialable(value: unknown): string | null {
  const phone = text(value);
  if (!phone || !DIALABLE.test(phone)) return null;
  const digits = phone.replace(/\D/g, '').length;
  return digits >= 7 && digits <= 15 ? phone : null;
}

function emailAddress(value: unknown): string | null {
  const email = text(value);
  return email && email.length <= 254 && EMAIL_ADDRESS.test(email) ? email : null;
}

export function parseHelpContacts(data: unknown): HelpContact[] {
  return list(data, 'help_contacts').flatMap((item) => {
    const contact = record(item);
    const name = text(contact?.name);
    if (!contact || !name) return [];
    const phone = dialable(contact.phone);
    const email = emailAddress(contact.email);
    if (!phone && !email) return [];
    return [{ name, role: text(contact.role), phone, email, textOk: Boolean(phone) && bool(contact.text_ok) }];
  });
}

// ---------- GET /employee/profile ----------
// Served by ProfileController (M4-7):
// { legal_name, email, email_verified, phone, phone_confirmed,
//   address: { address_line1, address_line2, city, state, zip },
//   payment_method, emergency_contacts: [{ id, name, relationship, phone }],
//   address_request: { id, status, requested: {...}, submitted_at, decided_at, decision_note } | null,
//   other_request_pending }

export interface Address {
  line1: string;
  line2: string;
  city: string;
  state: string;
  zip: string;
}

export interface EmergencyContact {
  id: string;
  name: string;
  relationship: string;
  phone: string;
}

export type AddressRequestStatus = 'pending' | 'approved' | 'rejected' | 'superseded';

export interface AddressRequest {
  id: string;
  status: AddressRequestStatus;
  requested: Address;
  submittedAt: string | null;
  decidedAt: string | null;
  decisionNote: string | null;
}

export interface EmployeeProfile {
  legalName: string | null;
  email: string | null;
  emailVerified: boolean;
  phone: string | null;
  /** Without SMS, a code proves who the employee is, not that they own the phone (M4-3). */
  phoneConfirmed: boolean;
  address: Address | null;
  paymentMethod: PaymentMethod | null;
  emergencyContacts: EmergencyContact[];
  addressRequest: AddressRequest | null;
  /** A client user's change request for this employee is open, so a new one can't start yet (M4-7). */
  otherRequestPending: boolean;
}

function parseAddress(value: unknown): Address | null {
  const address = record(value);
  if (!address) return null;
  const parsed = {
    line1: text(address.address_line1) ?? text(address.line1) ?? '',
    line2: text(address.address_line2) ?? text(address.line2) ?? '',
    city: text(address.city) ?? '',
    state: text(address.state) ?? '',
    zip: text(address.zip) ?? '',
  };
  return parsed.line1 || parsed.city || parsed.zip ? parsed : null;
}

export function parseProfile(data: unknown): EmployeeProfile {
  const body = record(record(data)?.profile) ?? record(data) ?? {};
  const request = record(body.address_request);
  const requested = parseAddress(request?.requested);
  const requestId = id(request?.id);
  const status = oneOf(request?.status, ['pending', 'approved', 'rejected', 'superseded'] as const);
  return {
    legalName: text(body.legal_name),
    email: text(body.email),
    emailVerified: bool(body.email_verified),
    phone: text(body.phone),
    phoneConfirmed: bool(body.phone_confirmed),
    address: parseAddress(body.address),
    paymentMethod: oneOf(body.payment_method, ['direct_deposit', 'paper_check'] as const),
    emergencyContacts: list(body.emergency_contacts, 'emergency_contacts').flatMap((item) => {
      const contact = record(item);
      const contactId = id(contact?.id);
      const name = text(contact?.name);
      return contact && contactId && name
        ? [{ id: contactId, name, relationship: text(contact.relationship) ?? '', phone: text(contact.phone) ?? '' }] : [];
    }),
    addressRequest: request && requestId && status && requested ? {
      id: requestId,
      status,
      requested,
      submittedAt: accessDay(request.submitted_at),
      decidedAt: accessDay(request.decided_at),
      decisionNote: text(request.decision_note),
    } : null,
    otherRequestPending: bool(body.other_request_pending),
  };
}

/** The address fields the API takes, named as on the employees table. */
export function addressBody(address: Address): Record<string, string> {
  return { address_line1: address.line1.trim(), address_line2: address.line2.trim(), city: address.city.trim(), state: address.state.trim(), zip: address.zip.trim() };
}

// ---------- Changes (M4-7), all behind step-up (M4-1) ----------
// Each returns the updated profile, except where noted:
//   PATCH  /employee/profile/phone            { phone }
//   POST   /employee/profile/email            { email }  -> 202 { verification_id }; the API emails a code
//   POST   /employee/profile/email/confirm    { verification_id, code }
//   POST   /employee/emergency_contacts       { name, relationship, phone }
//   PATCH  /employee/emergency_contacts/:id   { name, relationship, phone }
//   DELETE /employee/emergency_contacts/:id
//   POST   /employee/address_requests         { address: {...} }
//   PATCH  /employee/address_requests/:id     { address: {...} }
//   DELETE /employee/address_requests/:id
// A step-up refusal is RecentVerification's 403 { clerk_error: { reason: "reverification-error" } }.

export function verificationIdFrom(data: unknown): string | null {
  return id(record(data)?.verification_id);
}

// ---------- Sign-up, claim and reactivation (M4-2, served) ----------
// Every check sends a token (from the invite link's #token) or a printed
// code, plus date of birth and SSN last 4, in the JSON body only: the API
// refuses any of them in the query string (EmployeeLinkCheckParams).
//
// POST /employee/activation, before any session (ActivationsController):
//   { token | code, date_of_birth, ssn_last4, email, use_for_notices, terms_version? }
//   -> 200 { next: "sign_up", sign_up_url, message: null }
//   -> 200 { next: "sign_in", sign_up_url: null, message }: this email can't start a new
//      account (it may already have one). One answer for every reason, so it never says which.
//   -> 422 { code: "activation_failed" } for every failed check, including a locked invite
//   -> 503 { code: "activation_unavailable" }
// POST /employee/links/claim (AccountController#claim) and
// POST /employee/links/reactivate (ReactivationsController), signed in, behind step-up:
//   { token | code, date_of_birth, ssn_last4 } -> 201 { link: { id, company_name, ... } }
//   -> 404 { code: "claim_failed" } for every failed check, including a locked invite
// 5 failed checks lock the invite for 24 hours, but the answer stays the same
// 422 or 404 (no 423), so a lock never says the details were close.
// The API requires the current server-published terms version for acceptance.

export interface IdentityCheck {
  token?: string;
  code?: string;
  dateOfBirth: string;
  ssnLast4: string;
}

export function identityBody(check: IdentityCheck): Record<string, string> {
  const body: Record<string, string> = { date_of_birth: check.dateOfBirth, ssn_last4: check.ssnLast4 };
  if (check.token) body.token = check.token;
  else if (check.code) body.code = check.code;
  return body;
}

export type ActivationOutcome = { next: 'sign_up'; signUpUrl: string } | { next: 'sign_in' };

/** The Clerk invitation URL the API returns. Only https (or this site, in development) is followed. */
export function signUpUrlFrom(data: unknown, pageOrigin: string): string | null {
  const raw = text(record(data)?.sign_up_url);
  if (!raw) return null;
  try {
    const url = new URL(raw, pageOrigin);
    return url.protocol === 'https:' || url.origin === pageOrigin ? url.toString() : null;
  } catch {
    return null;
  }
}

/** Null when the answer is neither outcome, or a sign-up without a URL this app will open. */
export function parseActivation(data: unknown, pageOrigin: string): ActivationOutcome | null {
  const next = record(data)?.next;
  if (next === 'sign_in') return { next: 'sign_in' };
  if (next !== 'sign_up') return null;
  const signUpUrl = signUpUrlFrom(data, pageOrigin);
  return signUpUrl ? { next: 'sign_up', signUpUrl } : null;
}

// ---------- Electronic-delivery consent (M4-6) ----------
// Served by DeliveryConsentsController:
//   GET  /employee/delivery_consents
//   POST /employee/delivery_consents                  (step-up; W-2GU also needs PDF access proof)
//   POST /employee/delivery_consents/withdraw         (one tap, no step-up)
//   POST /employee/delivery_consents/w2gu_access_proof/pdf

export type DeliveryConsentKind = 'pay_statements' | 'w2gu';
export type DeliveryConsentStatus = 'not_consented' | 'consented' | 'withdrawn';

export interface DeliveryDisclosure {
  version: string;
  title: string;
  text: string;
  digest: string;
  publishedAt: string | null;
  /** True only for staff/dev when disclosure status is draft; false for regular employees. */
  draftMarker: boolean;
}

export interface ActiveDeliveryConsent {
  id: string;
  disclosureVersion: string;
  disclosureDigest: string;
  givenAt: string;
  method: string;
  matchesCurrentDisclosure: boolean;
}

export interface DeliveryConsentItem {
  kind: DeliveryConsentKind;
  status: DeliveryConsentStatus;
  activeConsent: ActiveDeliveryConsent | null;
  lastWithdrawnAt: string | null;
  disclosure: DeliveryDisclosure | null;
  requiresAccessProof: boolean;
  emailNoticeLockedOn: boolean;
  paperContinues: boolean;
  electronicOnlyReady: boolean;
}

export interface DeliveryConsentsState {
  paperDeliveryContinues: boolean;
  consents: DeliveryConsentItem[];
}

export interface W2GuAccessProofChallenge {
  accessProofToken: string;
  expiresAt: string;
  filename: string;
  pdfBase64: string;
}

function parseDisclosure(value: unknown): DeliveryDisclosure | null {
  const row = record(value);
  const version = text(row?.version);
  const title = text(row?.title);
  const body = typeof row?.text === 'string' && row.text.trim() !== '' ? row.text : null;
  const digest = text(row?.digest);
  if (!row || !version || !title || !body || !digest) return null;
  return {
    version,
    title,
    text: body,
    digest,
    publishedAt: text(row.published_at),
    draftMarker: bool(row.draft_marker),
  };
}

function parseActiveConsent(value: unknown): ActiveDeliveryConsent | null {
  const row = record(value);
  const consentId = id(row?.id);
  const disclosureVersion = text(row?.disclosure_version);
  const disclosureDigest = text(row?.disclosure_digest);
  const givenAt = text(row?.given_at);
  const method = text(row?.method);
  if (!row || !consentId || !disclosureVersion || !disclosureDigest || !givenAt || !method) return null;
  return {
    id: consentId,
    disclosureVersion,
    disclosureDigest,
    givenAt,
    method,
    matchesCurrentDisclosure: bool(row.matches_current_disclosure),
  };
}

export function parseDeliveryConsents(data: unknown): DeliveryConsentsState {
  const body = record(data) ?? {};
  const consents = list(body, 'consents').flatMap((item): DeliveryConsentItem[] => {
    const row = record(item);
    const kind = oneOf(row?.kind, ['pay_statements', 'w2gu'] as const);
    if (!row || !kind) return [];
    const status = oneOf(row.status, ['not_consented', 'consented', 'withdrawn'] as const) ?? 'not_consented';
    return [{
      kind,
      status,
      activeConsent: parseActiveConsent(row.active_consent),
      lastWithdrawnAt: text(row.last_withdrawn_at),
      disclosure: parseDisclosure(row.disclosure),
      requiresAccessProof: kind === 'w2gu' || bool(row.requires_access_proof),
      emailNoticeLockedOn: bool(row.email_notice_locked_on),
      paperContinues: row.paper_continues !== false,
      electronicOnlyReady: bool(row.electronic_only_ready),
    }];
  });
  return {
    paperDeliveryContinues: body.paper_delivery_continues !== false,
    consents,
  };
}

export function parseW2GuAccessProof(data: unknown): W2GuAccessProofChallenge | null {
  const body = record(data);
  const accessProofToken = text(body?.access_proof_token);
  const expiresAt = text(body?.expires_at);
  const filename = text(body?.filename) ?? 'w2gu-pdf-access-check.pdf';
  const pdfBase64 = text(body?.pdf_base64);
  if (!body || !accessProofToken || !expiresAt || !pdfBase64) return null;
  return { accessProofToken, expiresAt, filename, pdfBase64 };
}
