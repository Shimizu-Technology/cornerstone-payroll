// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { Organizations } from './Organizations';

const api = vi.hoisted(() => ({ list: vi.fn(), create: vi.fn() }));

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {},
  organizationsApi: { list: api.list, create: api.create },
  usersApi: {},
}));
vi.mock('@/components/layout/Header', () => ({ Header: ({ actions }: { actions?: ReactNode }) => <header>{actions}</header> }));
// Shows the tone each message is given, which is otherwise only colour.
vi.mock('@/components/ui/action-feedback', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/components/ui/action-feedback')>()),
  ActionFeedback: ({ tone, message }: { tone: string; message: string }) => <div data-testid={`feedback-${tone}`}>{message}</div>,
}));

beforeEach(() => {
  vi.clearAllMocks();
  api.list.mockResolvedValue({ data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 25 } });
});
afterEach(cleanup);

async function createOrganization(status: string, error: string | null = null) {
  api.create.mockResolvedValue({ data: { id: 3 }, invitation_delivery_status: status, invitation_sent: false, invitation_error: error });
  const user = userEvent.setup();
  render(<Organizations />);
  await user.click(await screen.findByRole('button', { name: /New Organization/ }));
  await user.type(screen.getByPlaceholderText('Organization name *'), 'Synthetic Firm');
  await user.type(screen.getByPlaceholderText('Primary company name *'), 'Synthetic Company');
  await user.type(screen.getByPlaceholderText('First admin email (optional)'), 'admin@example.test');
  await user.click(screen.getByRole('button', { name: 'Create Organization' }));
}

it.each([
  ['skipped', "Email delivery isn't set up on this server, so no invitation email was sent"],
  ['failed', 'Invitation email could not be submitted or queued'],
])('shows a %s invite email as a warning, not a success', async (status, error) => {
  await createOrganization(status, error);

  const warning = await screen.findByTestId('feedback-warning');
  expect(warning.textContent).toContain('Organization created.');
  expect(warning.textContent).toContain(error);
  expect(screen.queryByTestId('feedback-success')).toBeNull();
});

it('keeps a queued invite as a success', async () => {
  await createOrganization('queued');

  expect((await screen.findByTestId('feedback-success')).textContent).toContain('Invitation queued for email delivery.');
  expect(screen.queryByTestId('feedback-warning')).toBeNull();
});
