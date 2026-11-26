import { useEffect, useRef, useState, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactElement, type ReactNode } from 'react';
import { Link } from 'react-router';
import type { LucideIcon } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useBrand } from './contexts';
import { takeHeadingFocusRequest } from './focus';
import { useDocumentTitle } from './hooks';

type Variant = 'primary' | 'secondary' | 'quiet' | 'danger';

const variants: Record<Variant, string> = {
  primary: 'emp-btn-primary',
  secondary: 'emp-btn-secondary',
  quiet: 'emp-btn-quiet',
  danger: 'emp-btn-danger',
};

interface EmpButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  block?: boolean;
}

export function EmpButton({ variant = 'primary', block, className, type = 'button', ...props }: EmpButtonProps): ReactElement {
  return <button type={type} className={cn('emp-btn', variants[variant], block && 'emp-btn-block', className)} {...props} />;
}

interface EmpButtonLinkProps {
  to: string;
  variant?: Variant;
  block?: boolean;
  className?: string;
  state?: unknown;
  onClick?: () => void;
  children: ReactNode;
}

export function EmpButtonLink({ to, variant = 'primary', block, className, state, onClick, children }: EmpButtonLinkProps): ReactElement {
  return <Link to={to} state={state} onClick={onClick} className={cn('emp-btn', variants[variant], block && 'emp-btn-block', className)}>{children}</Link>;
}

/** The client's logo, or a monogram in the brand color when there's no logo or it fails to load. */
export function BrandMark({ size = 'md' }: { size?: 'md' | 'lg' }): ReactElement {
  const brand = useBrand();
  const [failed, setFailed] = useState(false);
  const box = size === 'lg' ? 'size-16 rounded-[18px] text-[2rem]' : 'size-10 rounded-xl text-lg';
  if (brand.logoUrl && !failed) {
    return (
      <img
        src={brand.logoUrl}
        alt=""
        referrerPolicy="no-referrer"
        className={cn(box, 'shrink-0 bg-white object-contain')}
        onError={() => setFailed(true)}
      />
    );
  }
  return (
    <span aria-hidden="true" className={cn(box, 'inline-grid shrink-0 place-items-center bg-[var(--action)] font-display font-extrabold leading-none text-white')}>
      {brand.monogram}
    </span>
  );
}

/**
 * One screen with one h1. Sets the tab title and resets scroll. `actions` sit
 * beside the heading; `before` (a Back link) sits above it.
 */
export function Page({ title, actions, before, children }: { title: string; actions?: ReactNode; before?: ReactNode; children: ReactNode }): ReactElement {
  const heading = useRef<HTMLHeadingElement>(null);
  useDocumentTitle(title);

  useEffect(() => {
    document.getElementById('emp-main')?.scrollTo?.(0, 0);
    if (takeHeadingFocusRequest()) heading.current?.focus({ preventScroll: true });
  }, []);

  return (
    <div className="emp-page">
      {before}
      <div className="emp-page-head">
        <h1 ref={heading} tabIndex={-1} className="emp-h1">{title}</h1>
        {actions}
      </div>
      {children}
    </div>
  );
}

/** A friendly "this will show here" card for screens that aren't built yet. */
export function Placeholder({ icon: Icon, title, children }: { icon: LucideIcon; title: string; children: ReactNode }): ReactElement {
  return (
    <div className="flex gap-4">
      <span aria-hidden="true" className="grid size-11 shrink-0 place-items-center rounded-xl bg-[var(--action-tint)] text-[var(--action)]">
        <Icon className="size-6" />
      </span>
      <div className="min-w-0 space-y-2">
        <h2 className="font-display text-[1.06rem] font-bold leading-snug text-neutral-900">{title}</h2>
        <div className="text-neutral-600">{children}</div>
      </div>
    </div>
  );
}

/** A white card. `title` adds a small heading at the top, and `action` sits to its right. */
export function Card({
  title,
  action,
  className,
  children,
  ...props
}: {
  title?: string;
  action?: ReactNode;
  className?: string;
  children: ReactNode;
  'data-print-target'?: 'true';
}): ReactElement {
  return (
    <section className={cn('emp-card', className)} aria-label={title} {...props}>
      {(title || action) && (
        <div className="emp-card-head">
          {title && <h2 className="emp-h2">{title}</h2>}
          {action}
        </div>
      )}
      <div className="emp-card-body">{children}</div>
    </section>
  );
}

type Tone = 'good' | 'neutral' | 'bad' | 'warn' | 'brand';

const tones: Record<Tone, string> = {
  good: 'bg-success-50 text-success-800',
  neutral: 'bg-neutral-100 text-neutral-800',
  bad: 'bg-danger-50 text-danger-800',
  warn: 'bg-warning-100 text-warning-900',
  brand: 'bg-[var(--accent)] text-[var(--accent-ink)]',
};

/** A small status label. Text always says the status; color only backs it up. */
export function Chip({ tone = 'neutral', icon: Icon, children, ...props }: { tone?: Tone; icon?: LucideIcon; children: ReactNode; 'data-testid'?: string }): ReactElement {
  return (
    <span className={cn('emp-chip', tones[tone])} {...props}>
      {Icon && <Icon aria-hidden="true" className="size-4 shrink-0" />}
      {children}
    </span>
  );
}

/**
 * A data card that couldn't load: offline, too many tries, or a server error.
 * The rest of the screen keeps working, and Try again reloads just this.
 */
export function LoadProblem({ kind, onRetry, what = 'this' }: { kind: 'offline' | 'rate_limited' | 'server'; onRetry: () => void; what?: string }): ReactElement {
  const message = kind === 'offline' ? `You're offline. Connect to Wi-Fi or data to see ${what}.`
    : kind === 'rate_limited' ? 'Too many tries. Wait a minute, then try again.'
      : `We couldn't load ${what}. Try again in a minute.`;
  return (
    <div className="flex flex-col items-start gap-2" role="alert">
      <p className="text-neutral-700">{message}</p>
      <EmpButton variant="secondary" className="emp-btn-small" onClick={onRetry}>Try again</EmpButton>
    </div>
  );
}

/** Grey bars while a card loads, so the layout doesn't jump. */
export function SkeletonRows({ rows = 3, label }: { rows?: number; label: string }): ReactElement {
  return (
    <div className="space-y-4" aria-busy="true">
      <span className="sr-only" role="status">{label}</span>
      {Array.from({ length: rows }, (_, row) => (
        <div key={row} className="flex justify-between gap-4">
          <div className="emp-skel h-4 w-1/2" />
          <div className="emp-skel h-4 w-[22%]" />
        </div>
      ))}
    </div>
  );
}

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  hint?: ReactNode;
  error?: string | null;
}

/** A labeled input. 52px tall, 16px+ text so phones don't zoom, and the hint and error tied to it. */
export function Field({ label, hint, error, id, className, ...props }: FieldProps): ReactElement {
  const fieldId = id ?? `emp-field-${label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
  const hintId = hint ? `${fieldId}-hint` : undefined;
  const errorId = error ? `${fieldId}-error` : undefined;
  return (
    <div className={cn('emp-field', className)}>
      <label htmlFor={fieldId} className="emp-label">{label}</label>
      {hint && <p id={hintId} className="emp-hint">{hint}</p>}
      <input
        id={fieldId}
        className="emp-input"
        aria-invalid={error ? true : undefined}
        aria-describedby={[hintId, errorId].filter(Boolean).join(' ') || undefined}
        {...props}
      />
      {error && <p id={errorId} className="emp-field-error">{error}</p>}
    </div>
  );
}

/** Small grey "Demo" pill (D-3). Render only when brand.demo or link.demo is true. */
export function DemoPill(): ReactElement {
  return <span className="emp-demo-pill">Demo</span>;
}

/** A message in a form: a problem (role=alert) or a confirmation (role=status). */
export function FormMessage({ tone, children }: { tone: 'bad' | 'good' | 'info'; children: ReactNode }): ReactElement {
  return (
    <div className={cn('emp-message', `emp-message-${tone}`)} role={tone === 'bad' ? 'alert' : 'status'}>
      {children}
    </div>
  );
}
