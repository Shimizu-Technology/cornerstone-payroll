// @vitest-environment jsdom
import { act, cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ClientDocument } from '@/services/api';
import { DocumentPreviewModal } from './DocumentPreviewModal';
const documentFile = { id: 4, title: 'November hours', file_name: 'hours.pdf', content_type: 'application/pdf' } as ClientDocument;
const api = { opened: vi.fn().mockResolvedValue(undefined), activity: vi.fn() };
const view = (open = true) => <DocumentPreviewModal open={open} onOpenChange={vi.fn()} document={documentFile} payload={null} loading={false} onDownload={vi.fn()} activityApi={api} />;
beforeEach(() => { vi.clearAllMocks(); Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' }); vi.spyOn(document, 'hasFocus').mockReturnValue(true); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
it('waits for a hidden or unfocused window to display the detail', async () => {
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' });
  vi.mocked(document.hasFocus).mockReturnValue(false); render(view()); expect(api.opened).not.toHaveBeenCalled();
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
  act(() => document.dispatchEvent(new Event('visibilitychange'))); expect(api.opened).not.toHaveBeenCalled();
  vi.mocked(document.hasFocus).mockReturnValue(true); act(() => window.dispatchEvent(new Event('focus')));
  await waitFor(() => expect(api.opened).toHaveBeenCalledWith(4));
  act(() => window.dispatchEvent(new Event('focus'))); expect(api.opened).toHaveBeenCalledOnce();
});
it('retries a rejected open and stops listening after close', async () => {
  api.opened.mockRejectedValueOnce(new Error('offline'));
  const rendered = render(view()); await act(async () => {});
  act(() => window.dispatchEvent(new Event('focus'))); await waitFor(() => expect(api.opened).toHaveBeenCalledTimes(2));
  rendered.rerender(view(false)); act(() => { window.dispatchEvent(new Event('focus')); document.dispatchEvent(new Event('visibilitychange')); });
  expect(api.opened).toHaveBeenCalledTimes(2);
});
