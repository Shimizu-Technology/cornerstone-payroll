// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { TenantComingSoon } from './TenantComingSoon';

const host = 'example-employer.shimizu-technology.com';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('TenantComingSoon', () => {
  it('shows the employer brand and coming-soon message using a credential-free fetch', async () => {
    const fetchBranding = vi.fn().mockResolvedValue(Response.json({
      name: 'Example Employer',
      logo_url: 'https://example.test/logo.png',
      primary_color: '#214F44',
      accent_color: '#FAD625',
    }));
    vi.stubGlobal('fetch', fetchBranding);

    render(<TenantComingSoon host={host} />);

    expect(await screen.findByRole('heading', { name: 'Employee portal coming soon' })).toBeTruthy();
    expect(screen.getByText('Example Employer')).toBeTruthy();
    expect(screen.getByText('Powered by Cornerstone Payroll')).toBeTruthy();
    expect(screen.getByAltText('').getAttribute('src')).toBe('https://example.test/logo.png');
    expect(screen.queryAllByRole('link')).toEqual([]);
    expect(screen.queryAllByRole('button')).toEqual([]);
    expect(screen.getByRole('main').style.borderTopColor).toBe('rgb(33, 79, 68)');
    expect(fetchBranding).toHaveBeenCalledWith(
      expect.stringContaining(`/api/v1/public/tenant_branding?host=${host}`),
      expect.objectContaining({ credentials: 'omit', signal: expect.any(AbortSignal) }),
    );
  });

  it('shows a generic unavailable page for a disabled or unknown tenant', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status: 404 })));

    render(<TenantComingSoon host={host} />);

    expect(await screen.findByRole('heading', { name: 'Employee portal unavailable' })).toBeTruthy();
    expect(screen.getByText('Please contact your employer if you need help.')).toBeTruthy();
    expect(screen.queryByText('Powered by Cornerstone Payroll')).toBeNull();
    expect(document.title).toBe('Employee Portal');
    expect(screen.queryAllByRole('link')).toEqual([]);
    expect(screen.queryAllByRole('button')).toEqual([]);
  });

  it('shows the generic fallback when the browser cannot reach the API', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));

    render(<TenantComingSoon host={host} />);

    expect(await screen.findByRole('heading', { name: 'Employee portal unavailable' })).toBeTruthy();
  });
});
