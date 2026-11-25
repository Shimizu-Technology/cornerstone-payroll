/** @vitest-environment jsdom */
import { ClerkInstanceContext } from '@clerk/shared/react';
import { cleanup, render } from '@testing-library/react';
import { useContext, type ContextType, type ReactElement } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { StepUpRequiredError } from './api';
import { ClerkAuthBridge } from './ClerkAuth';
import { EmployeeAuthContext, type EmployeeAuthValue } from './contexts';

const { openUserProfile } = vi.hoisted(() => ({ openUserProfile: vi.fn() }));

vi.mock('@clerk/react', async (importOriginal) => ({
  ...await importOriginal<typeof import('@clerk/react')>(),
  useAuth: () => ({ isLoaded: true, isSignedIn: true, getToken: vi.fn(async () => 'token'), signOut: vi.fn() }),
  useClerk: () => ({ openUserProfile }),
}));

type Clerk = NonNullable<ContextType<typeof ClerkInstanceContext>>['value'];
const openReverification = vi.fn<Clerk['__internal_openReverification']>();
const clerk = { __internal_openReverification: openReverification } as unknown as Clerk;

function renderBridge(): { current: EmployeeAuthValue } {
  const auth = {} as { current: EmployeeAuthValue };
  function Capture(): ReactElement | null {
    auth.current = useContext(EmployeeAuthContext) as EmployeeAuthValue;
    return null;
  }
  render(
    <ClerkInstanceContext.Provider value={{ value: clerk }}>
      <ClerkAuthBridge><Capture /></ClerkAuthBridge>
    </ClerkInstanceContext.Provider>,
  );
  return auth;
}

beforeEach(() => {
  openReverification.mockReset();
  openUserProfile.mockReset();
});
afterEach(cleanup);

describe('employee ClerkAuthBridge', () => {
  // The API asks for first_factor while REQUIRE_MFA is off (a password or email
  // code, never enrollment) and second_factor once it's on.
  it.each(['first_factor', 'second_factor'])('prompts Clerk at the API\'s %s level and retries the change', async (level) => {
    openReverification.mockImplementation((props) => props?.afterVerification?.({}));
    const attempt = vi.fn<() => Promise<string>>()
      .mockRejectedValueOnce(new StepUpRequiredError({ type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level, afterMinutes: 10 } } }))
      .mockResolvedValueOnce('saved');
    const auth = renderBridge();

    await expect(auth.current.stepUp(attempt)).resolves.toBe('saved');
    expect(openReverification).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ level }));
    expect(attempt).toHaveBeenCalledTimes(2);
  });

  it('opens Clerk account settings over the screen and offers the embedded panel', () => {
    const auth = renderBridge();
    auth.current.openAccountSettings();
    expect(openUserProfile).toHaveBeenCalledTimes(1);
    expect(auth.current.AccountSecurityPanel).toBeTypeOf('function');
  });
});
