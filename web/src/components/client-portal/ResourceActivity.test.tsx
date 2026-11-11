// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ResourceActivity } from './ResourceActivity';
afterEach(cleanup);
it('loads named activity only on expansion and uses Guam time', async () => {
  const api = { activity: vi.fn().mockResolvedValue({ data: [{ id: 1, headline: 'Dafne uploaded November hours', created_at: '2026-11-11T00:00:00Z', document_version: 4 }], meta: { current_page: 1, total_pages: 1 } }) };
  render(<ResourceActivity id={4} api={api} />);
  expect(api.activity).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
  expect(await screen.findByText('Dafne uploaded November hours')).toBeTruthy();
  expect(screen.getByText(/10:00 AM/)).toBeTruthy();
  expect(screen.getByText('Version 4')).toBeTruthy();
});
it('offers a retry for a failed history load', async () => {
  const api = { activity: vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValue({ data: [], meta: {} }) };
  render(<ResourceActivity id={4} api={api} />);
  fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
  expect(await screen.findByText('No activity recorded yet.')).toBeTruthy();
});
