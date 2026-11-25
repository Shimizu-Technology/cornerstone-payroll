import { expect, test, type Page } from '@playwright/test';
import { context, employeeBaseUrl, mockEmployeeApi, signIn, tenantQuery } from './employee-fixtures';

// Electronic-delivery consent UI checks (M4-6) at 390px (phone) and 1280px (desktop).
// Fictional data only.
test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local employee dev server');
test.use({ baseURL: employeeBaseUrl });

const PAY_DIGEST = 'a'.repeat(64);
const W2_DIGEST = 'b'.repeat(64);
const SAMPLE_PDF_B64 = Buffer.from('%PDF-1.4\n1 0 obj <<>> endobj\ntrailer <<>>\n%%EOF').toString('base64');

function consentsPayload({
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
            id: 101,
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
          text: 'Purpose and scope\nCovers electronic pay statements under Guam UETA.\n\nRight to withdraw consent\nWithdraw anytime in one tap.',
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
            id: 102,
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
          text: 'Paper copy unless you consent\nPaper Form W-2GU continues unless you consent.\n\nConfirming you can open PDF files\nOpen the test PDF and enter the code shown inside.',
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

async function expectNoHorizontalScroll(page: Page): Promise<void> {
  expect(await page.evaluate(() => {
    const main = document.getElementById('emp-main');
    return document.documentElement.scrollWidth <= window.innerWidth && (!main || main.scrollWidth <= main.clientWidth);
  })).toBe(true);
}

for (const viewport of [
  { label: '390px phone', width: 390, height: 844 },
  { label: '1280px desktop', width: 1280, height: 800 },
]) {
  test(`delivery consent flow at ${viewport.label}`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await signIn(page);

    let payStatus: 'not_consented' | 'consented' | 'withdrawn' = 'not_consented';
    let w2Status: 'not_consented' | 'consented' | 'withdrawn' = 'not_consented';

    await mockEmployeeApi(page, {
      context: {
        ...context,
        features: { ...context.features, delivery_consent: true },
      },
    });

    await page.route('**/api/v1/employee/delivery_consents**', async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.pathname.endsWith('/w2gu_access_proof/pdf') && request.method() === 'POST') {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            access_proof_token: 'e2e-proof-token',
            expires_at: '2026-11-25T12:30:00Z',
            filename: 'w2gu-pdf-access-check.pdf',
            pdf_base64: SAMPLE_PDF_B64,
          }),
        });
        return;
      }
      if (url.pathname.endsWith('/withdraw') && request.method() === 'POST') {
        const body = request.postDataJSON() as { kind?: string };
        if (body.kind === 'w2gu') w2Status = 'withdrawn';
        else payStatus = 'withdrawn';
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify(consentsPayload({ payStatus, w2Status, draftMarker: false })),
        });
        return;
      }
      if (request.method() === 'POST') {
        if (request.headers().authorization !== 'Bearer dev-preview-token-verified') {
          await route.fulfill({
            status: 403,
            contentType: 'application/json',
            body: JSON.stringify({
              clerk_error: {
                type: 'forbidden',
                reason: 'reverification-error',
                metadata: { reverification: { level: 'first_factor', afterMinutes: 10 } },
              },
            }),
          });
          return;
        }
        const body = request.postDataJSON() as { kind?: string };
        if (body.kind === 'w2gu') w2Status = 'consented';
        else payStatus = 'consented';
        await route.fulfill({
          status: 201,
          contentType: 'application/json',
          body: JSON.stringify(consentsPayload({ payStatus, w2Status, draftMarker: false })),
        });
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(consentsPayload({ payStatus, w2Status, draftMarker: false })),
      });
    });

    // Open Tax forms and complete W-2GU PDF access-proof + step-up consent + one-tap withdraw
    await page.goto(`/taxes?${tenantQuery}`);
    const w2Card = page.getByRole('region', { name: 'Electronic Form W-2GU' });
    await expect(w2Card).toBeVisible();
    await expect(page.getByTestId('draft-wording-marker')).toHaveCount(0);
    await expect(w2Card).not.toContainText(/\bpilot\b/i);
    await expect(w2Card.getByText('Paper Form W-2GU continues unless you consent.')).toBeHidden();
    await w2Card.getByRole('button', { name: 'Read the disclosure' }).click();
    await expect(w2Card.getByText('Paper Form W-2GU continues unless you consent.')).toBeVisible();
    await expectNoHorizontalScroll(page);

    await w2Card.getByRole('button', { name: 'Open test PDF' }).click();
    await w2Card.getByLabel('Code from the test PDF').fill('K7M4RT');
    await w2Card.getByRole('checkbox').check();
    await w2Card.getByRole('button', { name: 'Consent to electronic Form W-2GU' }).click();

    // Dev preview step-up prompt appears and confirms
    const stepUp = page.getByTestId('dev-preview-step-up');
    await expect(stepUp).toBeVisible();
    await stepUp.getByRole('button', { name: 'Confirm' }).click();

    await expect(page.getByText(/Consent recorded for electronic Form W-2GU/)).toBeVisible();
    await expect(w2Card.getByText('Electronic consent on file')).toBeVisible();
    await expectNoHorizontalScroll(page);

    // One-tap withdraw with confirmation
    await w2Card.getByRole('button', { name: 'Switch back to paper (withdraw consent)' }).click();
    await w2Card.getByRole('button', { name: 'Confirm paper delivery' }).click();
    await expect(page.getByText("Saved. You'll get paper copies.")).toBeVisible();
    await expect(w2Card.getByText('Paper delivery (withdrawn)')).toBeVisible();
    await expectNoHorizontalScroll(page);

    // My info shows both pay statements and W-2GU consent cards cleanly
    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'My info' }).click();
    await expect(page.getByRole('region', { name: 'Electronic pay statements' })).toBeVisible();
    await expect(page.getByRole('region', { name: 'Electronic Form W-2GU' })).toBeVisible();
    await expectNoHorizontalScroll(page);
  });
}
