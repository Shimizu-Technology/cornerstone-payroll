// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FinanceAgentAccess } from './FinanceAgentAccess';

const state = vi.hoisted(() => ({
  bookId: 1,
  list: vi.fn(),
  create: vi.fn(),
  revoke: vi.fn(),
}));

vi.mock('@/contexts/FinanceBookContext', () => ({
  useFinanceBook: () => ({ activeBook: { id: state.bookId, organization_id: 7, name: `Book ${state.bookId}` } }),
  FinanceBookSelector: () => null,
}));
vi.mock('@/components/layout/Header', () => ({ Header: ({ title }: { title: string }) => <h1>{title}</h1> }));
vi.mock('@/services/api', () => ({ financeApiTokensApi: state, getApiBaseUrl: () => 'https://example.com/api/v1' }));

function token(id: number, bookId: number) {
  return { id, name: `Key ${id}`, organization_id: 1, finance_book_id: bookId, scopes: ['read'],
    expires_at: '2026-12-31T00:00:00Z', revoked_at: null, last_used_at: null, created_at: '2026-09-29T00:00:00Z' };
}

describe('FinanceAgentAccess', () => {
  beforeEach(() => {
    state.bookId = 1;
    state.list.mockReset();
    state.create.mockReset();
    state.revoke.mockReset();
  });
  afterEach(cleanup);

  it('hides the previous book’s keys while another book loads', async () => {
    state.list.mockResolvedValueOnce({ finance_book_id: 1, tokens: [token(10, 1)] });
    let finishSecondLoad!: (value: { finance_book_id: number; tokens: ReturnType<typeof token>[] }) => void;
    state.list.mockImplementationOnce(() => new Promise((resolve) => { finishSecondLoad = resolve; }));
    const view = render(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    expect(await screen.findByText('Key 10')).toBeTruthy();

    state.bookId = 2;
    view.rerender(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    expect(screen.queryByText('Key 10')).toBeNull();
    expect(screen.getByText('Loading keys…')).toBeTruthy();

    finishSecondLoad({ finance_book_id: 2, tokens: [token(20, 2)] });
    expect(await screen.findByText('Key 20')).toBeTruthy();
    expect(screen.queryByText('Key 10')).toBeNull();
  });

  it('shows a new secret once and hides it after switching books', async () => {
    state.list.mockResolvedValueOnce({ finance_book_id: 1, tokens: [] });
    state.list.mockResolvedValueOnce({ finance_book_id: 2, tokens: [] });
    state.create.mockResolvedValue({ token: token(10, 1), secret: 'cfin_test_secret' });
    const user = userEvent.setup();
    const view = render(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText('No agent keys yet.')).toBeTruthy());
    await user.type(screen.getByPlaceholderText('Shimizu invoice agent'), 'Test agent');
    await user.click(screen.getByRole('button', { name: 'Create key' }));
    expect(await screen.findByDisplayValue('cfin_test_secret')).toBeTruthy();

    state.bookId = 2;
    view.rerender(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    expect(screen.queryByDisplayValue('cfin_test_secret')).toBeNull();
  });

  it('requires an inline confirmation before revoking a key', async () => {
    state.list.mockResolvedValue({ finance_book_id: 1, tokens: [token(10, 1)] });
    state.revoke.mockResolvedValue({ token: { ...token(10, 1), revoked_at: '2026-09-29T00:00:00Z' } });
    const user = userEvent.setup();
    render(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    await screen.findByText('Key 10');
    await user.click(screen.getByRole('button', { name: 'Revoke' }));
    expect(state.revoke).not.toHaveBeenCalled();
    expect(screen.getByText('This agent will lose access immediately.')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Confirm revoke' }));
    await waitFor(() => expect(state.revoke).toHaveBeenCalledWith(10));
    expect(await screen.findByText(/Key 10/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Revoke' })).toBeNull();
  });

  it('shows connection IDs and retries a failed key list', async () => {
    state.list.mockRejectedValueOnce(new Error('Temporary outage'));
    state.list.mockResolvedValueOnce({ finance_book_id: 1, tokens: [] });
    const user = userEvent.setup();
    render(<MemoryRouter><FinanceAgentAccess /></MemoryRouter>);
    expect(await screen.findByText('Temporary outage')).toBeTruthy();
    expect(screen.getByText('7')).toBeTruthy();
    expect(screen.getByText('https://example.com/api/v1')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Retry loading keys' }));
    expect(await screen.findByText('No agent keys yet.')).toBeTruthy();
  });
});
