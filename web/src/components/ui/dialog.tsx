import * as React from 'react';
import { createPortal } from 'react-dom';
import { cn } from '@/lib/utils';

interface DialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  children: React.ReactNode;
}

export function Dialog({ open, onOpenChange, children }: DialogProps) {
  if (!open) return null;

  if (typeof document === 'undefined') {
    return null;
  }

  return createPortal(
    <div className="fixed inset-0 z-[100]">
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
    </div>,
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
  return (
    <div
      className={cn(
        'mx-0 max-h-[92vh] overflow-y-auto rounded-t-3xl bg-white p-4 shadow-lg sm:mx-4 sm:rounded-lg sm:p-6',
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
  ...props
}: React.HTMLAttributes<HTMLHeadingElement>) {
  return (
    <h2
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
