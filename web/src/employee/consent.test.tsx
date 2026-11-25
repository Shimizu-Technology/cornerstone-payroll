// @vitest-environment jsdom
import { act, cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.hoisted(() => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '');
});

import EmployeeApp from '../EmployeeApp';

const PAY_DIGEST = 'a'.repeat(64);
const W2_DIGEST = 'b'.repeat(64);
const SAMPLE_PDF_B64 = btoa('%PDF-1.4\n1 0 obj <<>> endobj\ntrailer <<>>\n%%EOF');

function makeConsentsPayload({
  payStatus = 'not_consented',
  w2Status = 'not_consented',
  draftMarker = false,
}: {
  payStatus?: 'not_consented' | 'consented' | 'withdrawn';
  w2Status?: 'not_consented' | 'consented' | 'withdrawn';
  draftMarker?: boolean;
} = {}) {
  return {
    paper_delivery_continues: true,
    consents: [
      {
        kind: 'pay_statements',
        status: payStatus,
        active_consent: payStatus === 'consented'
          ? {
            id: 11,
            disclosure_version: '2026-11-25-draft-1',
            disclosure_digest: PAY_DIGEST,
            given_at: '2026-11-25T10:00:00Z',
            method: 'employee_portal_checkbox',
            matches_current_disclosure: true,
          }
          : null,
        last_withdrawn_at: payStatus === 'withdrawn' ? '2026-11-25T11:00:00Z' : null,
        disclosure: {
          version: '2026-11-25-draft-1',
          title: 'Electronic Pay Statement Delivery Consent',
          text: 'Purpose and scope\nElectronic pay statements under Guam UETA.\n\nRight to withdraw consent\nWithdraw in one tap.',
          digest: PAY_DIGEST,
          published_at: '2026-11-25T00:00:00Z',
          draft_marker: draftMarker,
        },
        requires_access_proof: false,
        email_notice_locked_on: false,
        paper_continues: true,
        electronic_only_ready: false,
      },
      {
        kind: 'w2gu',
        status: w2Status,
        active_consent: w2Status === 'consented'
          ? {
            id: 12,
            disclosure_version: '2026-11-25-draft-1',
            disclosure_digest: W2_DIGEST,
            given_at: '2026-11-25T10:05:00Z',
            method: 'employee_portal_pdf_verified',
            matches_current_disclosure: true,
          }
          : null,
        last_withdrawn_at: w2Status === 'withdrawn' ? '2026-11-25T11:15:00Z' : null,
        disclosure: {
          version: '2026-11-25-draft-1',
          title: 'Electronic Form W-2GU Delivery Consent',
          text: 'Paper copy unless you consent\nYou get paper Form W-2GU unless you consent.\n\nHardware and software requirements\nYou need a PDF viewer.',
          digest: W2_DIGEST,
          published_at: '2026-11-25T00:00:00Z',
          draft_marker: draftMarker,
        },
        requires_access_proof: true,
        email_notice_locked_on: w2Status === 'consented',
        paper_continues: true,
        electronic_only_ready: false,
      },
    ],
  };
}

function respond(routes: Record<string, (init?: RequestInit) => Response>): ReturnType<typeof vi.fn<typeof fetch>> {
  return vi.fn<typeof fetch>(async (input, init) => {
    const path = new URL(String(input), 'http://localhost').pathname.replace(/^\/api\/v1/, '');
    const key = `${init?.method ?? 'GET'} ${path}`;
    const handler = routes[key] ?? routes[path];
    return handler ? handler(init) : new Response(null, { status: 404 });
  });
}

const signedIn = (): void => sessionStorage.setItem('employee-dev-preview-signed-in', 'true');

beforeEach(() => {
  window.history.pushState({}, '', '/');
  URL.createObjectURL = vi.fn(() => 'blob:mock-pdf');
  URL.revokeObjectURL = vi.fn();
  HTMLAnchorElement.prototype.click = vi.fn();
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

describe('employee electronic-delivery consent screens', () => {
  it('hides consent screens completely when delivery_consent feature is off', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    const fetchMock = respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { stubs: true, tax_forms: true, profile_requests: true, delivery_consent: false },
      }),
      '/employee/profile': () => Response.json({ legal_name: 'Jordan Reyes', email: 'jordan@example.test' }),
      '/employee/tax_forms': () => Response.json({ tax_forms: [] }),
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    expect(await screen.findByRole('heading', { level: 1, name: 'My info' })).toBeTruthy();
    expect(screen.queryByRole('region', { name: 'Electronic pay statements' })).toBeNull();
    expect(screen.queryByRole('region', { name: 'Electronic Form W-2GU' })).toBeNull();

    // Also hidden on Tax forms
    await userEvent.click(within(screen.getByRole('navigation', { name: 'Main' })).getByRole('link', { name: 'Tax forms' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Tax forms' })).toBeTruthy();
    expect(screen.queryByRole('region', { name: 'Electronic Form W-2GU' })).toBeNull();
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes('/delivery_consents'))).toBe(false);
  });

  it('folds the disclosure away once consent is recorded', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(makeConsentsPayload({ payStatus: 'consented' })),
    }));
    render(<EmployeeApp />);

    const payCard = await screen.findByRole('region', { name: 'Electronic pay statements' });
    const toggle = within(payCard).getByRole('button', { name: 'Read the disclosure' });
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(within(payCard).getByText('Electronic pay statements under Guam UETA.').closest('[hidden]')).not.toBeNull();

    await userEvent.click(toggle);
    expect(toggle.getAttribute('aria-expanded')).toBe('true');
    expect(within(payCard).getByRole('button', { name: 'Hide the disclosure' })).toBe(toggle);
    expect(within(payCard).getByText('Electronic pay statements under Guam UETA.').closest('[hidden]')).toBeNull();
  });

  it('shows the full disclosure before consent, omits "pilot", and shows draft marker only for staff/dev', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(makeConsentsPayload({ draftMarker: false })),
    }));
    const first = render(<EmployeeApp />);

    const payCard = await screen.findByRole('region', { name: 'Electronic pay statements' });
    expect(within(payCard).getByText('Paper delivery')).toBeTruthy();
    expect(payCard.textContent).not.toMatch(/\bpilot\b/i);
    expect(within(payCard).getByText(/Paper copies continue for everyone for now\./)).toBeTruthy();
    // Consent can't be given with the disclosure folded away.
    expect(within(payCard).queryByRole('button', { name: 'Read the disclosure' })).toBeNull();
    expect(within(payCard).getByText('Electronic pay statements under Guam UETA.').closest('[hidden]')).toBeNull();
    expect(within(payCard).getByRole('checkbox')).toBeTruthy();
    expect(screen.queryByTestId('draft-wording-marker')).toBeNull();
    expect(screen.queryByText('Draft wording')).toBeNull();
    first.unmount();

    // Staff / dev response carries draft_marker: true
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(makeConsentsPayload({ draftMarker: true })),
    }));
    render(<EmployeeApp />);

    expect(await screen.findByRole('region', { name: 'Electronic pay statements' })).toBeTruthy();
    expect(screen.getAllByTestId('draft-wording-marker')).toHaveLength(2);
  });

  it('completes W-2GU PDF access-proof + step-up consent on Tax forms and supports one-tap withdraw with confirmation', async () => {
    signedIn();
    window.history.pushState({}, '', '/taxes');
    let consented = false;
    let withdrawn = false;
    let lastConsentBody: Record<string, unknown> | null = null;

    const fetchMock = respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { tax_forms: true, delivery_consent: true },
      }),
      '/employee/tax_forms': () => Response.json({ tax_forms: [] }),
      'GET /employee/delivery_consents': () => Response.json(
        makeConsentsPayload({ w2Status: consented ? 'consented' : withdrawn ? 'withdrawn' : 'not_consented' }),
      ),
      'POST /employee/delivery_consents/w2gu_access_proof/pdf': () => Response.json({
        access_proof_token: 'signed-token-123',
        expires_at: '2026-11-25T12:15:00Z',
        filename: 'w2gu-pdf-access-check.pdf',
        pdf_base64: SAMPLE_PDF_B64,
      }),
      'POST /employee/delivery_consents': (init) => {
        const headers = new Headers(init?.headers);
        if (headers.get('Authorization') !== 'Bearer dev-preview-token-verified') {
          return Response.json({
            clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level: 'first_factor', afterMinutes: 10 } } },
          }, { status: 403 });
        }
        lastConsentBody = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
        consented = true;
        return Response.json(makeConsentsPayload({ w2Status: 'consented' }), { status: 201 });
      },
      'POST /employee/delivery_consents/withdraw': () => {
        consented = false;
        withdrawn = true;
        return Response.json(makeConsentsPayload({ w2Status: 'withdrawn' }));
      },
    });
    vi.stubGlobal('fetch', fetchMock);
    render(<EmployeeApp />);

    const card = await screen.findByRole('region', { name: 'Electronic Form W-2GU' });
    const submitBtn = within(card).getByRole('button', { name: 'Consent to electronic Form W-2GU' });
    expect((submitBtn as HTMLButtonElement).disabled).toBe(true);

    // Step 1: Open test PDF and enter code
    await userEvent.click(within(card).getByRole('button', { name: 'Open test PDF' }));
    const codeInput = await within(card).findByLabelText('Code from the test PDF');
    await userEvent.type(codeInput, 'K7M4RT');

    // Step 2: Check agreement checkbox and submit -> triggers step-up dialog
    await userEvent.click(within(card).getByRole('checkbox'));
    expect((submitBtn as HTMLButtonElement).disabled).toBe(false);
    await userEvent.click(submitBtn);

    const dialog = await screen.findByTestId('dev-preview-step-up');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Confirm' }));

    expect(await screen.findByText(/Consent recorded for electronic Form W-2GU\. Paper copies still continue for now\./)).toBeTruthy();
    expect(document.body.textContent).not.toMatch(/\bpilot\b/i);
    expect(lastConsentBody).toMatchObject({
      kind: 'w2gu',
      acknowledged: true,
      disclosure_version: '2026-11-25-draft-1',
      disclosure_digest: W2_DIGEST,
      access_proof_token: 'signed-token-123',
      access_proof_code: 'K7M4RT',
    });
    expect(within(card).getByText(/Tax document availability email notices stay on/)).toBeTruthy();

    // Step 3: One-tap withdraw with neutral confirmation (no step-up dialog, no Cornerstone wording)
    await userEvent.click(within(card).getByRole('button', { name: 'Switch back to paper (withdraw consent)' }));
    const confirmRegion = within(card).getByRole('region', { name: 'Confirm paper delivery' });
    expect(confirmRegion.textContent).not.toMatch(/Cornerstone/i);
    await userEvent.click(within(confirmRegion).getByRole('button', { name: 'Confirm paper delivery' }));
    expect(await screen.findByText("Saved. You'll get paper copies.")).toBeTruthy();
    expect(screen.queryByTestId('dev-preview-step-up')).toBeNull();
  });

  it('lets a former employee withdraw an active consent while hiding new opt-in forms', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    let payStatus: 'consented' | 'withdrawn' = 'consented';
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({
        links: [{ id: 3, company_name: 'Harbor Finch', status: 'former', former_access_until: '2028-11-25' }],
      }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'former',
        former_access_until: '2028-11-25',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(makeConsentsPayload({ payStatus, w2Status: 'not_consented' })),
      'POST /employee/delivery_consents/withdraw': () => {
        payStatus = 'withdrawn';
        return Response.json(makeConsentsPayload({ payStatus: 'withdrawn', w2Status: 'not_consented' }));
      },
    }));
    render(<EmployeeApp />);

    const payCard = await screen.findByRole('region', { name: 'Electronic pay statements' });
    const w2Card = screen.getByRole('region', { name: 'Electronic Form W-2GU' });
    // Former employees cannot give new consent
    expect(within(w2Card).queryByRole('button', { name: /Consent to electronic/ })).toBeNull();
    // Former employees CAN withdraw an active consent
    await userEvent.click(within(payCard).getByRole('button', { name: 'Switch back to paper (withdraw consent)' }));
    await userEvent.click(within(payCard).getByRole('button', { name: 'Confirm paper delivery' }));
    expect(await screen.findByText("Saved. You'll get paper copies.")).toBeTruthy();
  });

  it('targets only the clicked disclosure card when printing', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    const printSpy = vi.spyOn(window, 'print').mockImplementation(() => undefined);
    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(makeConsentsPayload()),
    }));
    render(<EmployeeApp />);

    const payCard = await screen.findByRole('region', { name: 'Electronic pay statements' });
    const w2Card = screen.getByRole('region', { name: 'Electronic Form W-2GU' });

    await userEvent.click(within(w2Card).getByRole('button', { name: 'Print' }));
    expect(printSpy).toHaveBeenCalledOnce();
    expect(document.body.classList.contains('emp-printing-disclosure')).toBe(true);
    expect(w2Card.getAttribute('data-print-target')).toBe('true');
    expect(within(w2Card).getByText('You need a PDF viewer.').closest('[hidden]')).toBeNull();
    expect(payCard.getAttribute('data-print-target')).toBeNull();

    act(() => {
      window.dispatchEvent(new Event('afterprint'));
    });
    expect(document.body.classList.contains('emp-printing-disclosure')).toBe(false);
    expect(w2Card.getAttribute('data-print-target')).toBeNull();
    printSpy.mockRestore();
  });

  it('formats consent and withdrawal UTC timestamps as Guam calendar dates across midnight', async () => {
    signedIn();
    window.history.pushState({}, '', '/my-info');
    // 2026-11-25T16:30:00Z is 2026-11-26 02:30 in Pacific/Guam (UTC+10).
    const payload = makeConsentsPayload({ payStatus: 'consented', w2Status: 'withdrawn' });
    payload.consents[0].active_consent!.given_at = '2026-11-25T16:30:00Z';
    payload.consents[1].last_withdrawn_at = '2026-11-25T18:45:00Z';

    vi.stubGlobal('fetch', respond({
      '/employee/links': () => Response.json({ links: [{ id: 3, company_name: 'Harbor Finch', status: 'active' }] }),
      '/employee/context': () => Response.json({
        first_name: 'Jordan',
        status: 'active',
        features: { profile_requests: false, delivery_consent: true },
      }),
      'GET /employee/delivery_consents': () => Response.json(payload),
    }));
    render(<EmployeeApp />);

    const payCard = await screen.findByRole('region', { name: 'Electronic pay statements' });
    const w2Card = screen.getByRole('region', { name: 'Electronic Form W-2GU' });
    expect(payCard.textContent).toContain('Nov 26, 2026');
    expect(payCard.textContent).not.toContain('Nov 25, 2026');
    expect(w2Card.textContent).toContain('Nov 26, 2026');
    expect(w2Card.textContent).not.toContain('Nov 25, 2026');
  });
});
