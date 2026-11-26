// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { PayrollOverrideActions } from './PayrollOverrideActions';

const mocks = vi.hoisted(() => ({ post: vi.fn(), retry: vi.fn() }));
vi.mock('@/services/api', () => ({ apiClient: { post: mocks.post } }));
vi.mock('@/lib/useOptionalStepUpRequest', () => ({ useOptionalStepUpRequest: () => mocks.retry }));

afterEach(cleanup);

it('submits the rollback review ID with a required reason and reloads the record', async () => {
  mocks.post.mockResolvedValue({});
  const reload = vi.fn();
  render(<PayrollOverrideActions companyId={8} periodId={5} reviewId="42" onReviewComplete={reload} />);
  expect(screen.queryByText('Re-run a stuck job')).toBeNull();
  fireEvent.click(screen.getByText('Mark rollback review complete'));
  expect((screen.getByRole('button', { name: 'Complete review' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Reviewed revised tax totals' } });
  fireEvent.click(screen.getByRole('button', { name: 'Complete review' }));
  await waitFor(() => expect(reload).toHaveBeenCalled());
  expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/5/complete_rollback_review',
    { review_id: '42', reason: 'Reviewed revised tax totals' }, { companyId: 8 });
});

it('queues only the chosen job through the fresh sign-in request', async () => {
  mocks.retry.mockResolvedValue({ ok: true });
  render(<PayrollOverrideActions companyId={8} periodId={5} canRetry onReviewComplete={vi.fn()} />);
  fireEvent.click(screen.getByText('Re-run a stuck job'));
  fireEvent.change(screen.getByLabelText('Job'), { target: { value: 'notification_dispatch' } });
  fireEvent.change(screen.getByLabelText('Reason'), { target: { value: 'Recover pending deliveries' } });
  fireEvent.click(screen.getByRole('button', { name: 'Queue retry' }));
  expect((await screen.findByRole('status')).textContent).toBe('Job retry queued for this client.');
  expect(mocks.retry).toHaveBeenCalledWith({ job: 'notification_dispatch', reason: 'Recover pending deliveries' });
});
