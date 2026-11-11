// @vitest-environment jsdom
import { act, cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ClientPortalThread } from '@/services/api';
import { useDisplayedMessages } from './useDisplayedMessages';
let callback: IntersectionObserverCallback;
const mark = vi.fn().mockResolvedValue({});
const topic = { id: 4, display_token: 'signed-range', messages: [{ id: 12 }] } as ClientPortalThread;
function View({ enabled = true, thread = topic }: { enabled?: boolean; thread?: ClientPortalThread }) {
  const ref = useDisplayedMessages(thread, enabled, mark);
  return <div ref={ref}><div data-message-id="12">Displayed message</div></div>;
}
function intersect(visible: boolean) {
  act(() => callback([{ target: document.querySelector('[data-message-id]')!, isIntersecting: visible, intersectionRatio: visible ? 1 : 0 } as unknown as IntersectionObserverEntry], {} as IntersectionObserver));
}
beforeEach(() => {
  vi.clearAllMocks();
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
  vi.spyOn(document, 'hasFocus').mockReturnValue(true);
  vi.spyOn(HTMLElement.prototype, 'getClientRects').mockReturnValue([{}] as unknown as DOMRectList);
  window.IntersectionObserver = class {
    constructor(cb: IntersectionObserverCallback) { callback = cb; }
    observe() {} unobserve() {} disconnect() {} takeRecords() { return []; }
    root = null; rootMargin = ''; thresholds = [];
  };
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
it('marks only the visible fetched range after foreground display', async () => {
  render(<View />); intersect(true);
  await waitFor(() => expect(mark).toHaveBeenCalledWith(4, { foreground: true, display_token: 'signed-range', displayed_message_ids: [12] }));
});
it('does not mark a hidden mobile pane or a prefetched thread', async () => {
  render(<View enabled={false} />);
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
});
it('does not mark a background window or offscreen messages on reconnect', async () => {
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' });
  const view = render(<View />); intersect(true);
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
  view.rerender(<View thread={{ ...topic, display_token: 'refetched-after-reconnect' }} />);
  intersect(false);
  act(() => window.dispatchEvent(new Event('focus')));
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
});
it('does not accept Cable messages without a fetched display token', async () => {
  render(<View thread={{ ...topic, display_token: undefined }} />);
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
});
it('waits for focus, then records a still visible range', async () => {
  vi.mocked(document.hasFocus).mockReturnValue(false);
  render(<View />); intersect(true);
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
  vi.mocked(document.hasFocus).mockReturnValue(true);
  act(() => window.dispatchEvent(new Event('focus')));
  await waitFor(() => expect(mark).toHaveBeenCalledOnce());
});

it('does not mark a conversation covered by a modal', async () => {
  render(<div inert><View /></div>); intersect(true);
  await new Promise(resolve => setTimeout(resolve, 250));
  expect(mark).not.toHaveBeenCalled();
});
