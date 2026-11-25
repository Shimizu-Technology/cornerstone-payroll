// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, renderHook, waitFor } from '@testing-library/react';
import { fetchEmployeeTerms, useEmployeeTerms } from './terms';

describe('employee terms', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('distinguishes a network error from missing terms and clears the error on retry', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(new Response(null, { status: 503 })));

    const { result } = renderHook(() => useEmployeeTerms());
    await waitFor(() => expect(result.current.loadFailed).toBe(true));
    expect(result.current.terms).toBeUndefined();

    act(() => result.current.reload());
    await waitFor(() => expect(result.current.terms).toBeNull());
    expect(result.current.loadFailed).toBe(false);
  });

  it('loads the version and links from the public API', async () => {
    const fetch = vi.fn().mockResolvedValue(Response.json({
      version: 'current', title: 'Employee App Terms', terms_url: '/terms', privacy_url: '/privacy',
    }));
    vi.stubGlobal('fetch', fetch);
    await expect(fetchEmployeeTerms('https://example.test/api/v1/')).resolves.toEqual({
      version: 'current', title: 'Employee App Terms', termsUrl: '/terms', privacyUrl: '/privacy',
    });
    expect(fetch).toHaveBeenCalledWith('https://example.test/api/v1/public/employee_terms', expect.objectContaining({
      cache: 'no-store', credentials: 'omit',
    }));
  });

  it('treats an unavailable version or unsafe links as missing terms', async () => {
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(new Response(null, { status: 503 }))
      .mockResolvedValueOnce(Response.json({ version: 'current', title: 'Terms', terms_url: '//example.test', privacy_url: '/privacy' })));
    await expect(fetchEmployeeTerms('/api/v1')).resolves.toBeNull();
    await expect(fetchEmployeeTerms('/api/v1')).resolves.toBeNull();
  });
});
