// @vitest-environment jsdom
import { cleanup, render, screen, fireEvent, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { FilingSubmitterCard } from './FilingSubmitterCard';
const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn() }));
vi.mock('@/services/api', () => ({ filingSubmitterApi: mocks }));
afterEach(cleanup);
beforeEach(() => {
  vi.clearAllMocks();
  mocks.get.mockResolvedValue({ exists: true, profile: {}, missing_fields: [], can_edit: true });
  mocks.update.mockResolvedValue({});
});
it('shows the DRT question and saves an optional TCC', async () => {
  render(<FilingSubmitterCard />);
  expect(await screen.findByText(/Add the transmitter control code/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'View submitter profile' }));
  fireEvent.change(screen.getByLabelText(/Transmitter control code/), { target: { value: 'ABCDE' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save submitter profile' }));
  await waitFor(() => expect(mocks.update).toHaveBeenCalledWith({ tcc: 'ABCDE' }));
});
it('keeps TCC read only for staff', async () => {
  mocks.get.mockResolvedValue({ exists: true, profile: { tcc: 'ABCDE' }, missing_fields: [], can_edit: false });
  render(<FilingSubmitterCard />);
  await screen.findByText('E-file details complete.');
  fireEvent.click(screen.getByRole('button', { name: 'View submitter profile' }));
  expect((screen.getByLabelText(/Transmitter control code/) as HTMLInputElement).disabled).toBe(true);
});
