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
  if (element.hasAttribute('data-dialog-portal') || element.hasAttribute('data-feedback-portal') || state.backgroundInertValues.has(element)) return;
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
  placement?: 'center' | 'left';
  returnFocusRef?: React.RefObject<HTMLElement | null>;
  onAfterClose?: () => void;
}

export function Dialog({ open, onOpenChange, children, dismissOnEscape = true, placement = 'center', returnFocusRef, onAfterClose }: DialogProps): React.ReactElement | null {
  // Retain the portal and focus ownership until the opacity exit settles.
  // Reopening cancels removal and CSS retargets the in-flight transition.
  const [present, setPresent] = React.useState(open);
  const active = open || present;
  React.useEffect(() => {
    if (open) {
      setPresent(true);
      return;
    }
    const exit = window.setTimeout(() => setPresent(false), 120);
    return () => window.clearTimeout(exit);
  }, [open]);
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

  React.useLayoutEffect(() => {
    if (!active || typeof document === 'undefined') return undefined;

    const portal = portalRef.current;
    if (!portal) return undefined;

    const previouslyFocused = returnFocusRef?.current ?? (document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null);
    acquireDialog(document, portal, previouslyFocused);

    const dialogElement = (): HTMLElement | null => portal.querySelector<HTMLElement>('[role="dialog"]');
    const focusableElements = (includeFeedback = false): HTMLElement[] => {
      const dialog = dialogElement();
      const withinDialog = dialog ? Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)) : [];
      const feedback = includeFeedback ? Array.from(document.querySelectorAll<HTMLElement>(`[data-feedback-portal] ${FOCUSABLE_SELECTOR.split(',').join(', [data-feedback-portal] ')}`)) : [];
      return [...withinDialog, ...feedback].filter((element) => element.offsetParent !== null && !element.closest('[inert]'));
    };
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (documentDialogStates.get(document)?.portals.at(-1)?.element !== portal) return;
      if (event.key === 'Escape') {
        if (event.target instanceof HTMLElement && event.target.closest('[data-feedback-portal]')) return;
        if (!dismissOnEscapeRef.current) return;
        event.preventDefault();
        onOpenChangeRef.current(false);
        return;
      }
      if (event.key !== 'Tab') return;

      const focusable = focusableElements(true);
      if (focusable.length === 0) {
        event.preventDefault();
        dialogElement()?.focus();
        return;
      }
      const index = focusable.indexOf(document.activeElement as HTMLElement);
      const next = event.shiftKey ? (index <= 0 ? focusable.length - 1 : index - 1) : (index + 1) % focusable.length;
      event.preventDefault();
      focusable[next]?.focus();
    };
    document.addEventListener('keydown', handleKeyDown, true);

    return () => {
      document.removeEventListener('keydown', handleKeyDown, true);
      releaseDialog(document, portal);
    };
  }, [active, returnFocusRef]);

  React.useEffect(() => {
    const portal = portalRef.current;
    if (!portal) return;
    if (!open) {
      // Finish focused field drafts before a rapid reopen resets their values.
      // The background stays inert until the exit completes.
      const focused = document.activeElement;
      if (focused instanceof HTMLElement && portal.contains(focused)) focused.blur();
      return;
    }
    const focusFrame = window.requestAnimationFrame(() => {
      const dialog = portal.querySelector<HTMLElement>('[role="dialog"]');
      const focused = document.activeElement;
      if (focused instanceof HTMLElement && focused !== dialog && dialog?.contains(focused)) return;
      const first = dialog && Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
        .find((element) => element.offsetParent !== null && !element.closest('[inert]'));
      (first || dialog)?.focus();
    });
    return () => window.cancelAnimationFrame(focusFrame);
  }, [open]);

  const onAfterCloseRef = React.useRef(onAfterClose);
  React.useLayoutEffect(() => { onAfterCloseRef.current = onAfterClose; }, [onAfterClose]);
  const previouslyActive = React.useRef(active);
  React.useEffect(() => {
    // Focus ownership has already been released by the effect cleanup above.
    if (!active && previouslyActive.current) onAfterCloseRef.current?.();
    previouslyActive.current = active;
  }, [active]);

  if (!active) return null;

  if (typeof document === 'undefined') {
    return null;
  }

  return createPortal(
    <DialogContext.Provider value={{ generatedTitleId, titleId, registerTitleId }}>
    <div ref={portalRef} data-dialog-portal data-state={open ? 'open' : 'closed'} className="fixed inset-0 z-[100]">
      <div
        data-dialog-backdrop
        className="dialog-backdrop absolute inset-0 bg-black/55"
        onClick={() => onOpenChange(false)}
      />

      <div className={cn('relative z-10 h-full', placement === 'left' ? 'pointer-events-none flex items-stretch' : 'overflow-y-auto p-4 sm:p-6')}
        onClick={(event) => { if (event.target === event.currentTarget) onOpenChange(false); }}>
        {placement === 'left' ? <div className="pointer-events-auto h-full w-[86vw] max-w-[320px]">{children}</div> : (
          <div className="flex min-h-full items-end justify-center py-0 sm:items-center sm:py-4 [&:has(.dialog-center-mobile)]:items-center [&:has(.dialog-top)]:items-start [&:has(.dialog-top)]:pt-8 sm:[&:has(.dialog-top)]:pt-12"
            onClick={(event) => { if (event.target === event.currentTarget) onOpenChange(false); }}>
            <div className="relative w-full max-w-lg [&:has(.dialog-wide)]:max-w-7xl">{children}</div>
          </div>
        )}
      </div>
    </div>
    </DialogContext.Provider>,
    document.body
  );
}

interface DialogContentProps extends React.HTMLAttributes<HTMLDivElement> {
  children: React.ReactNode;
  variant?: 'default' | 'drawer';
}

export function DialogContent({
  className,
  children,
  variant = 'default',
  ...props
}: DialogContentProps) {
  const context = React.useContext(DialogContext);
  const isFullyRoundedDialog = typeof className === 'string'
    && (className.includes('dialog-top') || className.includes('dialog-center-mobile'));

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby={props['aria-labelledby'] || (props['aria-label'] ? undefined : context?.titleId)}
      tabIndex={-1}
      className={cn(
        'dialog-panel bg-white',
        variant === 'drawer'
          ? 'relative flex h-full w-full overflow-y-auto'
          : cn('mx-0 max-h-[92dvh] overflow-y-auto p-4 shadow-lg sm:mx-4 sm:p-6', isFullyRoundedDialog ? 'rounded-3xl' : 'rounded-t-3xl rounded-b-none sm:rounded-lg'),
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
      className={cn('text-sm text-neutral-600', className)}
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
