// @vitest-environment jsdom
import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useStaleReview } from './useStaleReview';

vi.mock('@/services/api', () => ({ ApiError: class ApiError extends Error { status = 0; } }));

describe('useStaleReview', () => {
  it('ties the confirmation to the digest the reviewer saw', () => {
    const onRefresh = vi.fn().mockResolvedValue(undefined);
    const { result, rerender } = renderHook(({ digest }) => useStaleReview(digest, onRefresh), { initialProps: { digest: 'A' } });

    act(() => result.current.markRefused());
    rerender({ digest: 'B' });
    expect(result.current.canSubmit).toBe(false);
    act(() => result.current.setConfirmed(true));
    expect(result.current.canSubmit).toBe(true);

    // Another save reloads the checklist with newer evidence.
    rerender({ digest: 'C' });
    expect(result.current.confirmed).toBe(false);
    expect(result.current.canSubmit).toBe(false);
    act(() => result.current.setConfirmed(true));
    expect(result.current.canSubmit).toBe(true);
  });
});
