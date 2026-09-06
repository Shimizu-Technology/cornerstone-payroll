import * as React from 'react';
import { createPortal } from 'react-dom';
import { cn } from '@/lib/utils';

interface DialogContextValue {
  generatedTitleId: string;
  titleId: string;
  registerTitleId: (explicitId: string | null) => () => void;
}

const DialogContext = React.createContext<DialogContextValue | null>(null);

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'iframe',
  'details > summary',
  'audio[controls]',
  'video[controls]',
  '[contenteditable]:not([contenteditable="false"])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

interface DocumentDialogState {
  backgroundInertValues: Map<HTMLElement, string | null>;
  restoreTarget: HTMLElement | null;
  observer: MutationObserver;
  portals: Array<{ element: HTMLElement; restoreTarget: HTMLElement | null }>;
}

const documentDialogStates = new WeakMap<Document, DocumentDialogState>();

function setBackgroundInert(state: DocumentDialogState, element: HTMLElement): void {
  if (element.hasAttribute('data-dialog-portal') || state.backgroundInertValues.has(element)) return;
  state.backgroundInertValues.set(element, element.getAttribute('inert'));
  element.setAttribute('inert', '');
}

function updatePortalInert(state: DocumentDialogState): void {
  const topPortal = state.portals.at(-1)?.element;
  state.portals.forEach(({ element }) => {
    if (element === topPortal) element.removeAttribute('inert');
    else element.setAttribute('inert', '');
  });
}

function acquireDialog(documentValue: Document, portal: HTMLElement, restoreTarget: HTMLElement | null): void {
  let state = documentDialogStates.get(documentValue);
  if (!state) {
    const backgroundInertValues = new Map<HTMLElement, string | null>();
    state = {
      backgroundInertValues,
      restoreTarget,
      portals: [],
      observer: new MutationObserver((records) => {
        records.forEach((record) => record.addedNodes.forEach((node) => {
          if (node instanceof HTMLElement) setBackgroundInert(state!, node);
        }));
      }),
    };
    documentDialogStates.set(documentValue, state);
    Array.from(documentValue.body.children).forEach((element) => {
      if (element instanceof HTMLElement) setBackgroundInert(state!, element);
    });
    state.observer.observe(documentValue.body, { childList: true });
  }
  state.portals.push({ element: portal, restoreTarget });
  updatePortalInert(state);
}

function releaseDialog(documentValue: Document, portal: HTMLElement): void {
  const state = documentDialogStates.get(documentValue);
  if (!state) return;

  const portalIndex = state.portals.findIndex(({ element }) => element === portal);
  if (portalIndex === -1) return;
  const wasTopPortal = portalIndex === state.portals.length - 1;
  const [closedPortal] = state.portals.splice(portalIndex, 1);
  if (state.portals.length > 0) {
    updatePortalInert(state);
    if (wasTopPortal) {
      const restoreTarget = closedPortal.restoreTarget;
      if (restoreTarget?.isConnected && !restoreTarget.closest('[inert]')) {
        restoreTarget.focus();
      } else {
        state.portals.at(-1)?.element.querySelector<HTMLElement>('[role="dialog"]')?.focus();
      }
    }
    return;
  }

  state.observer.disconnect();
  state.backgroundInertValues.forEach((previousValue, element) => {
    if (previousValue === null) element.removeAttribute('inert');
    else element.setAttribute('inert', previousValue);
  });
  documentDialogStates.delete(documentValue);
  if (state.restoreTarget?.isConnected) state.restoreTarget.focus();
}

interface DialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  children: React.ReactNode;
  dismissOnEscape?: boolean;
}

export function Dialog({ open, onOpenChange, children, dismissOnEscape = true }: DialogProps): React.ReactElement | null {
  const generatedTitleId = React.useId();
  const [titleId, setTitleId] = React.useState(generatedTitleId);
  const portalRef = React.useRef<HTMLDivElement>(null);
  const onOpenChangeRef = React.useRef(onOpenChange);
  onOpenChangeRef.current = onOpenChange;
  const dismissOnEscapeRef = React.useRef(dismissOnEscape);
  dismissOnEscapeRef.current = dismissOnEscape;
  const registerTitleId = React.useCallback((explicitId: string | null): (() => void) => {
    const resolvedId = explicitId || generatedTitleId;
    setTitleId(resolvedId);
    return () => setTitleId((current) => current === resolvedId ? generatedTitleId : current);
  }, [generatedTitleId]);

  React.useEffect(() => {
    if (!open || typeof document === 'undefined') return undefined;

    const portal = portalRef.current;
    if (!portal) return undefined;

    const previouslyFocused = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    acquireDialog(document, portal, previouslyFocused);

    const dialogElement = (): HTMLElement | null => portal.querySelector<HTMLElement>('[role="dialog"]');
    const focusableElements = (): HTMLElement[] => {
      const dialog = dialogElement();
      return dialog
        ? Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)).filter((element) => element.offsetParent !== null)
        : [];
    };
    const focusFrame = window.requestAnimationFrame(() => {
      (focusableElements()[0] || dialogElement())?.focus();
    });
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (documentDialogStates.get(document)?.portals.at(-1)?.element !== portal) return;
      if (event.key === 'Escape') {
        if (!dismissOnEscapeRef.current) return;
        event.preventDefault();
        onOpenChangeRef.current(false);
        return;
      }
      if (event.key !== 'Tab') return;

      const focusable = focusableElements();
      if (focusable.length === 0) {
        event.preventDefault();
        dialogElement()?.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', handleKeyDown, true);

    return () => {
      window.cancelAnimationFrame(focusFrame);
      document.removeEventListener('keydown', handleKeyDown, true);
      releaseDialog(document, portal);
    };
  }, [open]);

  if (!open) return null;

  if (typeof document === 'undefined') {
    return null;
  }

  return createPortal(
    <DialogContext.Provider value={{ generatedTitleId, titleId, registerTitleId }}>
    <div ref={portalRef} data-dialog-portal className="fixed inset-0 z-[100]">
      <div
        className="absolute inset-0 bg-black/55 backdrop-blur-[1.5px]"
        onClick={() => onOpenChange(false)}
      />

      {/*
        Default modal sits at max-w-lg (~512px) — fine for confirmation dialogs.
        Any DialogContent that adds `.dialog-wide` opts into the wider tier:
          - lg+ screens: capped at max-w-7xl (1280px)
          - smaller screens: shrinks to fit (with the inner mx-4 gutter)
        ImportModal additionally opts into `.dialog-top` so the workflow starts near the
        top of the viewport instead of the vertical midpoint.
      */}
      <div className="relative z-10 h-full overflow-y-auto p-3 sm:p-6">
        <div className="flex min-h-full items-end justify-center py-0 sm:items-center sm:py-4 [&:has(.dialog-top)]:items-start [&:has(.dialog-top)]:pt-8 sm:[&:has(.dialog-top)]:pt-12">
          <div className="relative w-full max-w-lg [&:has(.dialog-wide)]:max-w-7xl">{children}</div>
        </div>
      </div>
    </div>
    </DialogContext.Provider>,
    document.body
  );
}

interface DialogContentProps extends React.HTMLAttributes<HTMLDivElement> {
  children: React.ReactNode;
}

export function DialogContent({
  className,
  children,
  ...props
}: DialogContentProps) {
  const context = React.useContext(DialogContext);
  const isTopAlignedDialog = typeof className === 'string' && className.includes('dialog-top');

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby={props['aria-labelledby'] || context?.titleId}
      tabIndex={-1}
      className={cn(
        'mx-0 max-h-[92vh] overflow-y-auto bg-white p-4 shadow-lg sm:mx-4 sm:rounded-lg sm:p-6',
        isTopAlignedDialog ? 'rounded-3xl' : 'rounded-t-3xl rounded-b-none sm:rounded-lg',
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}

export function DialogHeader({
  className,
  ...props
}: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('flex flex-col space-y-1.5 text-center sm:text-left', className)}
      {...props}
    />
  );
}

export function DialogTitle({
  className,
  id,
  ...props
}: React.HTMLAttributes<HTMLHeadingElement>) {
  const context = React.useContext(DialogContext);
  const resolvedId = id || context?.generatedTitleId;
  const registerTitleId = context?.registerTitleId;
  React.useLayoutEffect(() => registerTitleId?.(id || null), [id, registerTitleId]);
  return (
    <h2
      id={resolvedId}
      className={cn('text-lg font-semibold leading-none tracking-tight', className)}
      {...props}
    />
  );
}

export function DialogDescription({
  className,
  ...props
}: React.HTMLAttributes<HTMLParagraphElement>) {
  return (
    <p
      className={cn('text-sm text-gray-500', className)}
      {...props}
    />
  );
}

export function DialogFooter({
  className,
  ...props
}: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        'flex flex-col-reverse sm:flex-row sm:justify-end sm:space-x-2 pt-4',
        className
      )}
      {...props}
    />
  );
}
