import { useEffect, useRef, useState, type ButtonHTMLAttributes, type ReactElement, type ReactNode } from 'react';
import { Link } from 'react-router';
import type { LucideIcon } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useBrand } from './contexts';
import { takeHeadingFocusRequest } from './focus';
import { useDocumentTitle } from './hooks';

type Variant = 'primary' | 'secondary' | 'quiet';

const variants: Record<Variant, string> = {
  primary: 'emp-btn-primary',
  secondary: 'emp-btn-secondary',
  quiet: 'emp-btn-quiet',
};

interface EmpButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  block?: boolean;
}

export function EmpButton({ variant = 'primary', block, className, type = 'button', ...props }: EmpButtonProps): ReactElement {
  return <button type={type} className={cn('emp-btn', variants[variant], block && 'emp-btn-block', className)} {...props} />;
}

export function EmpButtonLink({ to, variant = 'primary', block, children }: { to: string; variant?: Variant; block?: boolean; children: ReactNode }): ReactElement {
  return <Link to={to} className={cn('emp-btn', variants[variant], block && 'emp-btn-block')}>{children}</Link>;
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

/** One screen with one h1. Sets the tab title and resets scroll. `actions` sit beside the heading. */
export function Page({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }): ReactElement {
  const heading = useRef<HTMLHeadingElement>(null);
  useDocumentTitle(title);

  useEffect(() => {
    document.getElementById('emp-main')?.scrollTo?.(0, 0);
    if (takeHeadingFocusRequest()) heading.current?.focus({ preventScroll: true });
  }, []);

  return (
    <div className="emp-page">
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
export function Card({ title, action, className, children }: { title?: string; action?: ReactNode; className?: string; children: ReactNode }): ReactElement {
  return (
    <section className={cn('emp-card', className)} aria-label={title}>
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
