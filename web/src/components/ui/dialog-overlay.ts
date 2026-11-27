const CLERK_DATA_ATTR_PREFIX = 'data-clerk';
const MAX_PORTAL_WRAPPER_DEPTH = 3;

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

/**
 * True only when a direct `document.body` child IS a Clerk root itself,
 * carries explicit Clerk / floating-ui portal attributes, or is a bare portal
 * wrapper whose sole direct wrapper chain leads straight to a Clerk root.
 * Never matches an app mount root like `#root` that merely embeds `<UserProfile>`.
 */
export function isClerkPortalRoot(element: Element): boolean {
  if (element.id === 'root') return false;
  if (hasClerkClass(element) || hasClerkAttribute(element)) return true;
  if (element.hasAttribute('data-floating-ui-portal')) return true;

  // Clerk's `Portal` appends a plain wrapper `<div>` directly to `document.body`
  // whose first/sole child is the Clerk backdrop/root. Walk at most a few
  // single-child anonymous wrapper divs so an app container with sibling UI
  // is never treated as a Clerk portal.
  let current: Element = element;
  for (let depth = 0; depth < MAX_PORTAL_WRAPPER_DEPTH; depth += 1) {
    if (current.children.length !== 1) return false;
    const onlyChild = current.firstElementChild;
    if (!onlyChild || onlyChild.id === 'root') return false;
    if (hasClerkClass(onlyChild) || hasClerkAttribute(onlyChild)) return true;
    if (onlyChild.tagName !== 'DIV' || onlyChild.id !== '') return false;
    current = onlyChild;
  }
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
