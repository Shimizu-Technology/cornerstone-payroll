// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { EmployeeDeliveryConsentPanel } from './EmployeeDeliveryConsentPanel';

afterEach(() => {
  cleanup();
});

describe('EmployeeDeliveryConsentPanel', () => {
  it('shows pay statement and W-2GU consent status with pilot and draft indicators for staff', () => {
    render(
      <EmployeeDeliveryConsentPanel
        summary={{
          feature_enabled: false,
          paper_delivery_continues: true,
          items: [
            {
              kind: 'pay_statements',
              status: 'consented',
              disclosure_version: '2026-11-25-draft-1',
              disclosure_status: 'draft',
              given_at: '2026-11-25T03:00:00Z',
              withdrawn_at: null,
              method: 'employee_portal_checkbox',
              electronic_only_ready: false,
              paper_continues: true,
            },
            {
              kind: 'w2gu',
              status: 'withdrawn',
              disclosure_version: '2026-11-25-draft-1',
              disclosure_status: 'draft',
              given_at: '2026-11-24T03:00:00Z',
              withdrawn_at: '2026-11-25T04:00:00Z',
              method: 'employee_portal_pdf_verified',
              electronic_only_ready: false,
              paper_continues: true,
            },
          ],
        }}
      />,
    );

    expect(screen.getByText('Electronic delivery consent')).toBeTruthy();
    expect(screen.getByText('Employee screens hidden')).toBeTruthy();
    expect(screen.getByText('Pay statements')).toBeTruthy();
    expect(screen.getByText('Paperless consent given')).toBeTruthy();
    expect(screen.getByText('Form W-2GU')).toBeTruthy();
    // Older responses without an answer: a withdrawal still reads as keep paper.
    expect(screen.getByText('Keep paper')).toBeTruthy();
    expect(screen.getAllByText('Draft wording')).toHaveLength(2);
    // Each badge says what it means in plain words.
    expect(screen.getByText(/Employees don't see these consent screens yet/)).toBeTruthy();
    expect(screen.getAllByText('The consent wording is still a draft waiting for counsel to approve it.')).toHaveLength(2);
  });

  it('leaves out the explanations when the screens are on and the wording is approved', () => {
    render(
      <EmployeeDeliveryConsentPanel
        summary={{
          feature_enabled: true,
          paper_delivery_continues: false,
          items: [{
            kind: 'pay_statements', status: 'not_consented', disclosure_version: '2026-11-25-v1', disclosure_status: 'approved',
            given_at: null, withdrawn_at: null, method: null, electronic_only_ready: false, paper_continues: false,
          }],
        }}
      />,
    );

    expect(screen.queryByText('Employee screens hidden')).toBeNull();
    expect(screen.queryByText(/Employees don't see these consent screens yet/)).toBeNull();
    expect(screen.queryByText(/still a draft/)).toBeNull();
    expect(screen.getByText('Not answered')).toBeTruthy();
    expect(screen.queryByText(/^Company:/)).toBeNull();
  });

  it('shows the employee answer and how the company answered, so staff see who still needs paper', () => {
    render(
      <EmployeeDeliveryConsentPanel
        summary={{
          feature_enabled: true,
          paper_delivery_continues: true,
          items: [
            {
              kind: 'pay_statements', status: 'not_consented', answer: 'keep_paper', paper_chosen_at: '2026-11-26T22:30:00Z',
              disclosure_version: null, disclosure_status: 'approved', given_at: null, withdrawn_at: null, method: null,
              electronic_only_ready: false, paper_continues: true,
            },
            {
              kind: 'w2gu', status: 'not_consented', answer: 'not_answered', paper_chosen_at: null,
              disclosure_version: null, disclosure_status: 'approved', given_at: null, withdrawn_at: null, method: null,
              electronic_only_ready: false, paper_continues: true,
            },
          ],
          company_counts: {
            pay_statements: { paperless: 3, keep_paper: 2, not_answered: 7, total: 12 },
            w2gu: { paperless: 0, keep_paper: 0, not_answered: 1, total: 1 },
          },
        }}
      />,
    );

    expect(screen.getByText('Keep paper')).toBeTruthy();
    expect(screen.getByText(/^Chose to keep paper .+ · Paper delivery required$/)).toBeTruthy();
    expect(screen.getByText('Not answered')).toBeTruthy();
    expect(screen.getByText("Hasn't answered yet. Paper delivery required.")).toBeTruthy();
    expect(screen.getByText('Company: 3 paperless · 2 keep paper · 7 not answered (12 active employees)')).toBeTruthy();
    expect(screen.getByText('Company: 0 paperless · 0 keep paper · 1 not answered (1 active employee)')).toBeTruthy();
  });
});
