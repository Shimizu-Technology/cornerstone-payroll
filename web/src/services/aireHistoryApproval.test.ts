// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { aireHistoryApprovalApi } from './aireHistoryApproval';

const api = vi.hoisted(() => ({ post: vi.fn(), get: vi.fn() }));
vi.mock('./api', () => ({ default: api }));
const queued = { operation_id: 12, status: 'queued', result: null, error: null };
const result = { review_id: 4, history_coverage_verified: true };
beforeEach(() => { vi.clearAllMocks(); vi.useFakeTimers(); api.post.mockResolvedValue(queued); });
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe('durable history operations', () => {
  it('submits once, then reads only local progress until the exact result completes', async () => {
    api.get.mockResolvedValue({ ...queued, status: 'completed', result });
    const task = aireHistoryApprovalApi.preview(1, 2);
    await vi.runAllTimersAsync();
    expect(await task).toEqual(result);
    expect(api.post).toHaveBeenCalledOnce();
    expect(api.post.mock.calls[0][1]).toEqual({ mapping_selections: [], background: true });
    expect(api.get).toHaveBeenCalledWith('/admin/time_tracking_sources/1/history_approval/operations/12', undefined, { companyId: 2, signal: undefined });
  });

  it('preserves the worker’s exact stale-evidence explanation', async () => {
    api.get.mockResolvedValue({ ...queued, status: 'failed', error: 'Entry 41 changed. Nothing was applied.' });
    const task = aireHistoryApprovalApi.preview(1, 2);
    const failure = expect(task).rejects.toThrow('Entry 41 changed');
    await vi.runAllTimersAsync();
    await failure;
  });

  it('stops polling when the page or client context is abandoned', async () => {
    const controller = new AbortController();
    const task = aireHistoryApprovalApi.preview(1, 2, [], controller.signal);
    const failure = expect(task).rejects.toHaveProperty('name', 'AbortError');
    await Promise.resolve(); controller.abort();
    await vi.runAllTimersAsync();
    await failure;
    expect(api.get).not.toHaveBeenCalled();
  });

  it('pauses local status reads while hidden and resumes when visible', async () => {
    const visibility = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden');
    api.get.mockResolvedValue({ ...queued, status: 'completed', result });
    const task = aireHistoryApprovalApi.preview(1, 2);
    await vi.advanceTimersByTimeAsync(5000);
    expect(api.get).not.toHaveBeenCalled();
    visibility.mockReturnValue('visible');
    await vi.runAllTimersAsync();
    expect(await task).toEqual(result);
  });
});
