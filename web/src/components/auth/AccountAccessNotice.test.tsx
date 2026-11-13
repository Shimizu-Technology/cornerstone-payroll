// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { AccountAccessNotice } from './AccountAccessNotice';
import { describeAuthProblem } from '@/lib/authProblem';

afterEach(cleanup);

it('says an inactive account is turned off and who to contact', () => {
  const { title, body } = describeAuthProblem({ status: 401, message: 'Account inactive' });
  expect(title).toBe('This account is turned off');
  expect(body).toMatch(/Contact Cornerstone/);
});

it('separates a login with no account, a refused workspace, and an unknown failure', () => {
  expect(describeAuthProblem({ status: 401, message: 'User not found' }).title).toMatch(/cannot open an account/);
  expect(describeAuthProblem({ status: 403, message: 'Staging access is restricted to named testers' }).title).toMatch(/cannot open the workspace/);
  expect(describeAuthProblem({ status: null, message: 'Failed to fetch' }).title).toMatch(/could not open your account/);
});

it('shows the server detail and offers only the actions it is given', () => {
  const retry = vi.fn();
  render(<AccountAccessNotice problem={{ status: 401, message: 'Account inactive' }} onRetry={retry} />);
  expect(screen.getByRole('alert').textContent).toMatch(/Detail from the server: Account inactive/);
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(retry).toHaveBeenCalled();
  expect(screen.queryByRole('button', { name: 'Sign in with a different account' })).toBeNull();
});
