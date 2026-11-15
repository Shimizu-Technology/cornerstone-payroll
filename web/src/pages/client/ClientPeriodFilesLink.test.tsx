// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ClientPeriodFilesLink } from './ClientPayPeriodDetail';
const get = vi.hoisted(() => vi.fn());
vi.mock('@/services/payrollSubmissions', () => ({ clientPayrollSubmissionsApi: { get } }));
afterEach(cleanup);
it('links to the authorized period and hides the link when access is refused', async () => {
  get.mockResolvedValueOnce({ data: { ref: '42' } });
  const view = render(<MemoryRouter><ClientPeriodFilesLink startDate="2026-10-19" endDate="2026-11-01" /></MemoryRouter>);
  expect((await screen.findByRole('link', { name: 'Pay Period Files' })).getAttribute('href')).toBe('/payroll-files/42');
  get.mockRejectedValueOnce(new Error('Forbidden'));
  view.rerender(<MemoryRouter><ClientPeriodFilesLink startDate="2026-11-02" endDate="2026-11-15" /></MemoryRouter>);
  await waitFor(() => expect(screen.queryByRole('link')).toBeNull());
});
