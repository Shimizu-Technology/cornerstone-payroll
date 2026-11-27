// @vitest-environment jsdom
import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useSupportView } from './useSupportView';

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe('useSupportView', () => {
  it('still leaves to the staff site after the grant expires', async () => {
    const expiresAt = new Date(Date.now() + 200).toISOString();
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ name: 'Worker', company_id: 1, expires_at: expiresAt, employee_url: null, staff_url: 'https://payroll.example.com' })));
    const replace = vi.fn();
    vi.spyOn(window, 'location', 'get').mockReturnValue({ ...window.location, origin: 'https://emp.example.com', replace } as Location);
    const getToken = async () => 'token';
    const { result } = renderHook(() => useSupportView('https://api.example.com/api/v1', getToken, '/'));

    await waitFor(() => expect(result.current.grant?.name).toBe('Worker'));
    await waitFor(() => expect(result.current.loadError).toBe('This support view has ended.'));
    expect(result.current.grant).toBeNull();

    act(() => { result.current.leave(); });
    expect(replace).toHaveBeenCalledWith('https://payroll.example.com/app');
  });
});
