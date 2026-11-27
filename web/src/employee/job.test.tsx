// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';
import { parseJob } from './contracts';
import { HIDE_AMOUNTS_KEY } from './preferences';

// Fictional people and company.
const JOB = {
  employer_name: 'Harbor Finch Kitchen',
  department: 'Front of House',
  role: 'Server',
  employee_id: '1042',
  worker_type: 'w2',
  pay_frequency: 'biweekly',
  pay: { type: 'hourly', rates: [{ label: 'Server', rate: '17.75' }] },
  start_date: '2024-03-04',
  payment_method: 'direct_deposit',
  contact_name: 'Rina Calvo',
};

function mockRoutes(job: unknown, context: Record<string, unknown> = {}): ReturnType<typeof vi.fn<typeof fetch>> {
  const routes: Record<string, () => Response> = {
    '/employee/links': () => Response.json({ links: [{ id: 42, company_name: 'Harbor Finch Kitchen', status: 'active' }] }),
    '/employee/context': () => Response.json({
      first_name: 'Maren', status: 'active', next_payday: '2026-12-04', w2_delivery: 'mailed',
      features: { stubs: false, tax_forms: false, profile_requests: false }, ...context,
    }),
    '/employee/help': () => Response.json({ help_contacts: [] }),
  };
  if (job !== undefined) routes['/employee/job'] = () => Response.json({ job });
  return vi.fn<typeof fetch>(async (input) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const handler = routes[path];
    return handler ? handler() : new Response(null, { status: 404 });
  });
}

function show(path: string, job: unknown, context?: Record<string, unknown>): void {
  window.history.pushState({}, '', path);
  vi.stubGlobal('fetch', mockRoutes(job, context));
  render(<EmployeeApp />);
}

async function jobCard(): Promise<HTMLElement> {
  await screen.findByText('Employment type');
  return screen.getByRole('region', { name: 'My job' });
}

function rows(card: HTMLElement): string[] {
  return Array.from(card.querySelectorAll('dt')).map((term) => term.textContent ?? '');
}

beforeEach(() => {
  sessionStorage.setItem('employee-dev-preview-signed-in', 'true');
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
    // Some tests block storage.
  }
  vi.unstubAllGlobals();
});

describe('My job', () => {
  it('shows the job, pay setup and who to contact, with the pay rate masked until Show amounts', async () => {
    show('/my-info', JOB);
    const card = await jobCard();
    expect(rows(card)).toEqual(['Employer', 'Job title', 'Department', 'Pay', 'Paid', 'Next payday', "How you're paid", 'Employment type', 'Start date', 'Employee ID']);
    expect(card.textContent).toContain('Harbor Finch Kitchen');
    expect(card.textContent).toContain('Every two weeks');
    expect(card.textContent).toContain('Employee (W-2)');
    expect(card.textContent).toContain('Direct deposit');
    expect(card.textContent).toContain('1042');

    // Masked by default: no figure in the text, and screen readers hear "Amount hidden".
    expect(card.textContent).not.toContain('17.75');
    expect(within(card).getByText('Amount hidden')).toBeTruthy();
    await userEvent.click(within(card).getByRole('button', { name: 'Show amounts' }));
    expect(card.textContent).toContain('$17.75 an hour');

    expect(within(card).getByRole('link', { name: 'Contact Rina Calvo' }).getAttribute('href')).toBe('/help');
  });

  it('lists each job with its own rate', async () => {
    show('/my-info', { ...JOB, pay: { type: 'hourly', rates: [{ label: 'Server', rate: '17.75' }, { label: 'Bartender', rate: '18.25' }] } });
    const card = await jobCard();
    expect(rows(card)).toContain('Pay rates');
    await userEvent.click(within(card).getByRole('button', { name: 'Show amounts' }));
    const items = within(card).getAllByRole('listitem').map((item) => item.textContent);
    expect(items).toEqual(['Server$17.75 an hour', 'Bartender$18.25 an hour']);
  });

  it('leaves out rows with nothing set instead of saying "None", and names the employer when there are no Help contacts', async () => {
    // With no method set, the API answers paper check, as payroll pays.
    show('/my-info', { ...JOB, role: null, department: null, start_date: null, payment_method: 'paper_check', contact_name: null }, { next_payday: null });
    const card = await jobCard();
    expect(rows(card)).toEqual(['Employer', 'Pay', 'Paid', "How you're paid", 'Employment type', 'Employee ID']);
    expect(card.textContent).toContain('Paper check');
    expect(card.textContent).not.toMatch(/None|Not added/);
    expect(within(card).getByRole('link', { name: 'Contact Harbor Finch Kitchen' })).toBeTruthy();
  });

  it('gives a salary per payday and per year, and a contractor plainly', async () => {
    localStorage.setItem(HIDE_AMOUNTS_KEY, 'false');
    show('/my-info', { ...JOB, pay: { type: 'salary', per_period: '2000.00', annual: '52000.00' } });
    let card = await jobCard();
    expect(card.textContent).toContain('$2,000.00 each payday');
    expect(card.textContent).toContain('$52,000.00 a year');
    cleanup();

    show('/my-info', { ...JOB, worker_type: '1099', pay_frequency: 'weekly', pay: { type: 'flat_fee', per_period: '800.00' } });
    card = await jobCard();
    expect(card.textContent).toContain('Contractor (1099)');
    expect(card.textContent).toContain('Every week');
    expect(card.textContent).toContain('$800.00 each payday');
    cleanup();

    // A salary set each pay period has no amount, so there's nothing to hide.
    show('/my-info', { ...JOB, pay: { type: 'salary', per_period: null, annual: null } });
    card = await jobCard();
    expect(card.textContent).toContain('Set each pay period');
    expect(within(card).queryByRole('button', { name: /Show amounts|Hide amounts/ })).toBeNull();
  });

  it('notes a rate change that reaches the next paycheck, per job, masked like the rate', async () => {
    show('/my-info', { ...JOB, pay: { type: 'hourly', rates: [
      { label: 'Server', rate: '15.00', change: { rate: '17.00', effective_on: '2026-12-01' } },
      { label: 'Bartender', rate: '18.25', change: null },
    ] } });
    const card = await jobCard();
    expect(card.textContent).toContain('Changes to $•••Amount hidden an hour on Dec 1');
    expect(card.textContent).not.toContain('17.00');
    await userEvent.click(within(card).getByRole('button', { name: 'Show amounts' }));
    const items = within(card).getAllByRole('listitem').map((item) => item.textContent);
    expect(items).toEqual(['Server$15.00 an hourChanges to $17.00 an hour on Dec 1', 'Bartender$18.25 an hour']);
    cleanup();

    show('/my-info', { ...JOB, pay: { type: 'hourly', rates: [{ label: null, rate: '15.00', change: { rate: '17.00', effective_on: '2026-12-01' } }] } });
    expect((await jobCard()).textContent).toContain('$15.00 an hourChanges to $17.00 an hour on Dec 1');
  });

  it('notes a salary change per payday, and shows the original hire date after a rehire', async () => {
    localStorage.setItem(HIDE_AMOUNTS_KEY, 'false');
    show('/my-info', {
      ...JOB, start_date: '2026-11-02', first_hired_on: '2026-03-09',
      pay: { type: 'salary', per_period: '2000.00', annual: '52000.00', change: { per_period: '2200.00', annual: '57200.00', effective_on: '2026-12-01' } },
    });
    const card = await jobCard();
    expect(card.textContent).toContain('Changes to $2,200.00 each payday ($57,200.00 a year) on Dec 1');
    expect(card.textContent).toContain('Nov 2, 2026');
    expect(card.textContent).toContain('Originally hired Mar 9, 2026');
  });

  it('puts the job title and department under the Home greeting', async () => {
    show('/', JOB);
    expect(await screen.findByText('Server · Front of House')).toBeTruthy();
    cleanup();

    show('/', { ...JOB, role: null });
    await screen.findByRole('heading', { level: 1, name: 'Hi, Maren' });
    expect(await screen.findByText('Front of House')).toBeTruthy();
  });

  it('shows nothing for a former job, and nothing when the API has no job route yet', async () => {
    show('/my-info', null, { status: 'former' });
    await screen.findByRole('heading', { level: 1, name: 'My info' });
    expect(screen.queryByRole('region', { name: 'My job' })).toBeNull();
    cleanup();

    // A 404 on the job alone (the link itself still opens) is not "access ended".
    show('/my-info', undefined);
    await screen.findByRole('heading', { level: 1, name: 'My info' });
    await vi.waitFor(() => expect(screen.queryByText('Loading your job')).toBeNull());
    expect(screen.queryByRole('region', { name: 'My job' })).toBeNull();
    expect(screen.getByRole('heading', { level: 1, name: 'My info' })).toBeTruthy();
  });
});

describe('parseJob', () => {
  it('drops rates it cannot use and reads a missing job as nothing', () => {
    expect(parseJob({ job: null })).toBeNull();
    expect(parseJob({})).toBeNull();
    const job = parseJob({ job: { ...JOB, pay: { type: 'hourly', rates: [{ label: 'Server', rate: 'n/a' }, { label: ' ', rate: '12.5' }] }, worker_type: 'other' } });
    expect(job?.pay).toEqual({ type: 'hourly', rates: [{ label: null, rate: '12.5', change: null }] });
    expect(job?.workerType).toBe('w2');
  });
});
