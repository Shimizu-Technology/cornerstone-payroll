// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ResourceActivity } from './ResourceActivity';
afterEach(cleanup);
it('loads named activity only on expansion and uses Guam time', async () => {
  const api = { activity: vi.fn().mockResolvedValue({ data: [{ id: 1, headline: 'Dafne uploaded November hours', created_at: '2026-11-11T00:00:00Z' }], meta: { current_page: 1, total_pages: 1 } }) };
  render(<ResourceActivity id={4} api={api} />);
  expect(api.activity).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
  expect(await screen.findByText('Dafne uploaded November hours')).toBeTruthy();
  expect(screen.getByText(/10:00 AM/)).toBeTruthy();
  expect(screen.queryByText(/Version/)).toBeNull();
});
it('offers a retry for a failed history load', async () => {
  const api = { activity: vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue({ data: [], meta: {} }) };
  render(<ResourceActivity id={4} api={api} />);
  fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
  expect(await screen.findByText('No activity recorded yet.')).toBeTruthy();
});

it('ignores an old page after Activity closes and reloads', async () => {
  let finish!: (response: unknown) => void;
  const meta = { current_page: 1, total_pages: 2, total_count: 2, per_page: 1 };
  const event = (id: number, headline: string) => ({ id, headline, created_at: '2026-11-11T00:00:00Z' });
  const api = { activity: vi.fn().mockResolvedValueOnce({ data: [event(1, 'Initial activity')], meta })
    .mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }))
    .mockResolvedValue({ data: [event(3, 'Fresh activity')], meta }) };
  render(<ResourceActivity id={4} api={api} />);
  fireEvent.click(screen.getByRole('button', { name: 'Activity' })); await screen.findByText('Initial activity');
  fireEvent.click(screen.getByRole('button', { name: 'Load more activity' }));
  fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
  fireEvent.click(screen.getByRole('button', { name: 'Activity' })); await screen.findByText('Fresh activity');
  await act(async () => finish({ data: [event(2, 'Stale page')], meta: { ...meta, current_page: 2 } }));
  expect(screen.queryByText('Stale page')).toBeNull();
});
