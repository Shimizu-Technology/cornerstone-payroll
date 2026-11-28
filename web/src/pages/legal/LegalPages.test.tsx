// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it } from 'vitest';
import { PrivacyPolicy } from './PrivacyPolicy';
import { TermsOfService } from './TermsOfService';
import { LEGAL_LAST_UPDATED } from './LegalLayout';

afterEach(cleanup);

function renderPage(page: React.ReactElement) {
  return render(<MemoryRouter>{page}</MemoryRouter>);
}

describe('PrivacyPolicy', () => {
  it('names the operator, the payroll service provider, and every service provider that receives data', () => {
    renderPage(<PrivacyPolicy />);

    expect(screen.getByRole('heading', { level: 1, name: 'Privacy Policy' })).toBeTruthy();
    expect(screen.getByText(`Last updated ${LEGAL_LAST_UPDATED}`)).toBeTruthy();
    expect(document.title).toBe('Privacy Policy · Cornerstone Payroll');
    expect(screen.getAllByText(/Shimizu Technology/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/Cornerstone Accounting and Business Management/).length).toBeGreaterThan(0);

    const providers = within(screen.getByRole('table')).getAllByRole('rowheader').map(cell => cell.textContent);
    expect(providers).toEqual([
      'Clerk',
      'Render',
      'Neon',
      'Cloudflare',
      'Netlify',
      'Resend',
      'Google',
      'PostHog',
      'OpenRouter and the AI model provider it connects to',
    ]);
  });

  it('states the commitments a reviewer relies on', () => {
    renderPage(<PrivacyPolicy />);

    expect(screen.getByText(/We do not sell personal information/)).toBeTruthy();
    expect(screen.getByText(/Social Security numbers, contractor EINs, and bank account details are encrypted in the database/)).toBeTruthy();
    const analyticsHeading = screen.getByRole('heading', { level: 3, name: 'Analytics' });
    const analyticsSection = within(analyticsHeading.closest('section')!);
    expect(analyticsSection.getByText(/anonymous device-level usage events through PostHog/i)).toBeTruthy();
    expect(analyticsSection.getByText(/app surface \(staff\s+or employee\)/i)).toBeTruthy();
    expect(analyticsSection.getByText(/account role \(on the staff site only\)/i)).toBeTruthy();
    expect(analyticsSection.getByText(/page route templates with IDs removed/i)).toBeTruthy();
    expect(analyticsSection.getByText(/named product\s+events.*carrying no amounts, names, or IDs/i)).toBeTruthy();
    expect(analyticsSection.getByText(/do not send names, email addresses, company or user IDs/i)).toBeTruthy();
    expect(analyticsSection.getByText(/on-screen text, or form contents/i)).toBeTruthy();
    expect(analyticsSection.getByText(/do not use session recordings; IP addresses are discarded/i)).toBeTruthy();
    expect(analyticsSection.getByText(/honor Do Not Track and Global Privacy Control/i)).toBeTruthy();
    expect(analyticsSection.getByText(/pending counsel review/i)).toBeTruthy();
    expect(screen.getByRole('link', { name: 'support@shimizu-technology.com' }).getAttribute('href')).toBe('mailto:support@shimizu-technology.com');
  });

  it('discloses fonts, connected time apps, and every AI use, and does not promise automatic deletion', () => {
    renderPage(<PrivacyPolicy />);

    expect(screen.getByText(/serves the web fonts your browser loads \(Google Fonts\)/)).toBeTruthy();
    expect(screen.getByText(/pulls payroll details from emails that staff paste in or files they upload/)).toBeTruthy();
    expect(screen.getByText(/to sync pay-period schedules, hours, and payment status/)).toBeTruthy();
    expect(screen.queryByText(/After that we delete the records/)).toBeNull();
    expect(screen.getByText(/a client may ask us to delete them/)).toBeTruthy();
  });

  it('uses page landmarks and marks the current page in the legal footer', () => {
    render(<MemoryRouter initialEntries={['/privacy']}><PrivacyPolicy /></MemoryRouter>);

    expect(screen.getByRole('banner')).toBeTruthy();
    expect(screen.getByRole('main')).toBeTruthy();
    expect(screen.getByRole('contentinfo')).toBeTruthy();
    const legalNav = screen.getByRole('navigation', { name: 'Legal' });
    expect(within(legalNav).getByRole('link', { name: 'Privacy Policy' }).getAttribute('aria-current')).toBe('page');
    expect(within(legalNav).getByRole('link', { name: 'Terms of Service' }).getAttribute('href')).toBe('/terms');
    expect(within(legalNav).getByRole('link', { name: 'Home' }).getAttribute('href')).toBe('/');
  });
});

describe('TermsOfService', () => {
  it('defers to a written agreement and links to the privacy policy', () => {
    renderPage(<TermsOfService />);

    expect(screen.getByRole('link', { name: 'support@shimizu-technology.com' }).getAttribute('href')).toBe('mailto:support@shimizu-technology.com');

    expect(screen.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeTruthy();
    expect(screen.getByText(/If your organization has a written agreement with us, that agreement controls/)).toBeTruthy();
    expect(screen.getByText(/separate agreement with\s+Cornerstone governs Cornerstone's payroll and accounting services/)).toBeTruthy();
    expect(screen.getByText(/advance notice when practicable/)).toBeTruthy();
    expect(screen.getByText('Access is by invitation only.', { exact: false })).toBeTruthy();
    expect(screen.getByText('These terms are governed by the laws of Guam.')).toBeTruthy();

    const privacyLinks = screen.getAllByRole('link', { name: 'Privacy Policy' });
    expect(privacyLinks.every(link => link.getAttribute('href') === '/privacy')).toBe(true);
  });
});
