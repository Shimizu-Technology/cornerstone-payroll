const CLERK_DATA_ATTR_PREFIX = 'data-clerk';
const CLERK_DESCENDANT_SELECTOR = [
  '[class^="cl-"]',
  '[class*=" cl-"]',
  '[id^="cl-"]',
  '[data-clerk-portal]',
  '[data-clerk-component]',
  '[data-clerk-id]',
  '[data-clerk-modal]',
  '[data-clerk-dev-mode-overlay]',
  '[data-clerk-dev-mode-notice]',
].join(',');

const stepUpCounts = new WeakMap<Document, number>();
const stepUpListeners = new WeakMap<Document, Set<() => void>>();

function hasClerkClass(element: Element): boolean {
  for (const className of element.classList) {
    if (className.startsWith('cl-')) return true;
  }
  return false;
}

function hasClerkAttribute(element: Element): boolean {
  if (element.id.startsWith('cl-')) return true;
  for (const attr of element.attributes) {
    if (attr.name.startsWith(CLERK_DATA_ATTR_PREFIX)) return true;
  }
  return false;
}

/** True when `node` is a Clerk component root or sits inside one. */
export function isClerkOverlayElement(node: EventTarget | null): boolean {
  if (!(node instanceof Element)) return false;
  let current: Element | null = node;
  while (current) {
    if (hasClerkClass(current) || hasClerkAttribute(current)) return true;
    current = current.parentElement;
  }
  return false;
}

/** True when `element` is itself a Clerk root or hosts one inside a portal wrapper. */
export function containsClerkOverlay(element: Element): boolean {
  if (hasClerkClass(element) || hasClerkAttribute(element)) return true;
  if (element.querySelector(CLERK_DESCENDANT_SELECTOR) !== null) return true;
  return false;
}

export function isStepUpOverlayActive(doc: Document | null | undefined = typeof document !== 'undefined' ? document : null): boolean {
  if (!doc) return false;
  return (stepUpCounts.get(doc) ?? 0) > 0;
}

export function onStepUpOverlayStart(doc: Document, listener: () => void): () => void {
  let listeners = stepUpListeners.get(doc);
  if (!listeners) {
    listeners = new Set();
    stepUpListeners.set(doc, listeners);
  }
  listeners.add(listener);
  return () => {
    listeners?.delete(listener);
    if (listeners && listeners.size === 0) stepUpListeners.delete(doc);
  };
}

/**
 * Marks a Clerk step-up prompt as in progress for `doc`, so open Dialogs
 * never mark newly inserted portal roots inert or hijack their Tab/Escape keys.
 * Returns an idempotent release function.
 */
export function beginStepUpOverlay(doc: Document | null | undefined = typeof document !== 'undefined' ? document : null): () => void {
  if (!doc) return () => {};
  const previous = stepUpCounts.get(doc) ?? 0;
  stepUpCounts.set(doc, previous + 1);
  if (previous === 0) {
    stepUpListeners.get(doc)?.forEach((listener) => listener());
  }
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const current = stepUpCounts.get(doc) ?? 0;
    if (current <= 1) stepUpCounts.delete(doc);
    else stepUpCounts.set(doc, current - 1);
  };
}
