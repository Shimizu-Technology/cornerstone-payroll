// @vitest-environment jsdom
import { act, cleanup, render, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ReactElement } from 'react';
import { MemoryRouter } from 'react-router';
import { CommandPalette } from '@/components/layout/CommandPalette';
import type { ClientPortalThread } from '@/services/api';
import { useDisplayedMessages } from './useDisplayedMessages';
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => false }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ isAdmin: false, isSuperAdmin: false, isAccountant: true, isClient: false, hasCapability: () => false }) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ companies: [], activeCompany: { id: 1 }, canSwitchCompany: false, switchCompany: vi.fn() }) }));
let callback: IntersectionObserverCallback;
const mark = vi.fn().mockResolvedValue({});
const topic = { id: 4, display_token: 'signed-range', messages: [{ id: 12 }] } as ClientPortalThread;
function View({ enabled = true, thread = topic }: { enabled?: boolean; thread?: ClientPortalThread }): ReactElement {
  const ref = useDisplayedMessages(thread, enabled, mark);
  return <div ref={ref}><div data-message-id="12">Displayed message</div></div>;
}
function intersect(visible: boolean): void {
  act(() => callback([{ target: document.querySelector('[data-message-id]')!, isIntersecting: visible, intersectionRatio: visible ? 1 : 0 } as unknown as IntersectionObserverEntry], {} as IntersectionObserver));
}
beforeEach(() => {
  vi.clearAllMocks();
  Element.prototype.scrollIntoView = vi.fn();
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

it('pauses for the actual command palette and resumes when it closes', async () => {
  const view = (open: boolean) => <><View /><MemoryRouter><CommandPalette open={open} onOpenChange={vi.fn()} /></MemoryRouter></>;
  const rendered = render(view(true)); intersect(true);
  await new Promise(resolve => setTimeout(resolve, 250)); expect(mark).not.toHaveBeenCalled();
  rendered.rerender(view(false)); await waitFor(() => expect(mark).toHaveBeenCalledOnce());
});

it('reports every message shown so far, so seeing 12, then 11, then 12 again reads both', async () => {
  const pair = { id: 5, display_token: 'signed-pair', messages: [{ id: 11 }, { id: 12 }] } as ClientPortalThread;
  function Pair(): ReactElement {
    const ref = useDisplayedMessages(pair, true, mark);
    return <div ref={ref}><div data-message-id="11">Earlier</div><div data-message-id="12">Later</div></div>;
  }
  const show = (shownIds: number[]): void => act(() => callback([11, 12].map(id => ({
    target: document.querySelector(`[data-message-id="${id}"]`)!, isIntersecting: shownIds.includes(id), intersectionRatio: shownIds.includes(id) ? 1 : 0,
  }) as unknown as IntersectionObserverEntry), {} as IntersectionObserver));
  render(<Pair />);

  show([12]);
  await waitFor(() => expect(mark).toHaveBeenLastCalledWith(5, { foreground: true, display_token: 'signed-pair', displayed_message_ids: [12] }));
  show([11]);
  await waitFor(() => expect(mark).toHaveBeenLastCalledWith(5, { foreground: true, display_token: 'signed-pair', displayed_message_ids: [11, 12] }));
  show([12]);
  await new Promise(resolve => setTimeout(resolve, 300));
  expect(mark).toHaveBeenCalledTimes(2);
});
