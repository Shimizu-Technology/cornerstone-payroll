// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';

const TOKEN = 'b'.repeat(40);

describe('employee-main initial invite token stripping', () => {
  afterEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();
    sessionStorage.clear();
    window.history.replaceState(null, '', '/');
    document.body.innerHTML = '';
  });

  it('strips #token= from window.location before PostHogProvider renders/initializes', async () => {
    let hashSeenByPostHog: string | null = 'not-rendered';

    vi.doMock('../providers/PostHogProvider', () => ({
      PostHogProvider: ({ children }: { children: unknown }) => {
        hashSeenByPostHog = window.location.hash;
        return children;
      },
    }));
    vi.doMock('../App', () => ({ default: () => null }));
    vi.doMock('../components/StagingContext', () => ({ StagingContext: () => null }));

    const root = document.createElement('div');
    root.id = 'root';
    document.body.appendChild(root);

    window.history.replaceState(null, '', `/activate#token=${TOKEN}`);

    await import('../employee-main');
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(hashSeenByPostHog).toBe('');
    expect(window.location.hash).toBe('');
    const { currentInviteToken } = await import('./signupState');
    expect(currentInviteToken()).toBe(TOKEN);
  });
});
