import type { ReactElement, ReactNode } from 'react';
import { CircleAlert, LoaderCircle, Lock, Power, RefreshCw, Timer, WifiOff, type LucideIcon } from 'lucide-react';
import { cn } from '@/lib/utils';
import { askManager } from './brand';
import { useBrand } from './contexts';
import { useDocumentTitle } from './hooks';
import { EmpButton } from './ui';

function StateIcon({ icon: Icon, tone = 'neutral' }: { icon: LucideIcon; tone?: 'neutral' | 'bad' }): ReactElement {
  return (
    <span aria-hidden="true" className={cn('grid size-[72px] place-items-center rounded-full', tone === 'bad' ? 'bg-danger-50 text-danger-700' : 'bg-neutral-200 text-neutral-800')}>
      <Icon className="size-[34px]" />
    </span>
  );
}

interface InlineStateProps {
  icon: LucideIcon;
  tone?: 'neutral' | 'bad';
  title: string;
  children: ReactNode;
  onRetry: () => void;
  onSignOut: () => void;
}

/**
 * A centered message inside the signed-in frame. The tabs are hidden while it
 * shows, so it always offers its own way out: Try again, Sign out, and who to ask.
 */
function InlineState({ icon, tone, title, children, onRetry, onSignOut }: InlineStateProps): ReactElement {
  useDocumentTitle(title);
  const brand = useBrand();
  return (
    <div className="emp-state" role="alert">
      <StateIcon icon={icon} tone={tone} />
      <h1 className="emp-h1">{title}</h1>
      <div className="space-y-2 text-neutral-600">{children}</div>
      <EmpButton className="mt-2 min-w-[200px]" onClick={onRetry}>
        <RefreshCw aria-hidden="true" className="size-6" />
        Try again
      </EmpButton>
      <EmpButton variant="quiet" onClick={onSignOut}>Sign out</EmpButton>
      <p className="text-[0.88rem] text-neutral-600">{askManager(brand, 'Still not working? Ask your manager')}</p>
    </div>
  );
}

interface StateActions {
  onRetry: () => void;
  onSignOut: () => void;
}

/** Laid out like Home: one column on a phone, two from 1024px. */
export function LoadingState(): ReactElement {
  useDocumentTitle('Loading');
  const bar = (className: string): ReactElement => <div className={cn('emp-skel', className)} />;
  const rows = (count: number): ReactElement[] => Array.from({ length: count }, (_, row) => (
    <div key={row} className="flex justify-between gap-4">
      {bar('h-4 w-1/2')}
      {bar('h-4 w-[22%]')}
    </div>
  ));
  return (
    <div className="emp-page" aria-busy="true">
      <span className="sr-only" role="status">Loading your pay…</span>
      {bar('h-8 w-[45%] max-w-64')}
      <div className="emp-home-grid">
        <div className="emp-column">
          <div className="emp-card space-y-4 p-4">
            {bar('h-4 w-[55%]')}
            {bar('h-12 w-[70%]')}
            {bar('h-4 w-[40%]')}
            {bar('h-12 w-full')}
          </div>
          <div className="emp-card space-y-4 p-4">{rows(4)}</div>
        </div>
        <div className="emp-column emp-wide-only">
          <div className="emp-card space-y-4 p-4">
            {bar('h-6 w-[60%]')}
            {bar('h-4 w-[40%]')}
          </div>
          <div className="emp-card space-y-4 p-4">{rows(3)}</div>
        </div>
      </div>
    </div>
  );
}

export function OfflineState(actions: StateActions): ReactElement {
  return (
    <InlineState icon={WifiOff} title="No internet connection" {...actions}>
      <p>For your privacy, your pay isn't saved on this phone. Connect to Wi-Fi or data to see it.</p>
    </InlineState>
  );
}

export function ErrorState(actions: StateActions): ReactElement {
  return (
    <InlineState icon={CircleAlert} tone="bad" title="Something went wrong" {...actions}>
      <p>It's a problem on our end. Your pay info is safe. Try again in a minute.</p>
    </InlineState>
  );
}

export function RateLimitedState(actions: StateActions): ReactElement {
  return (
    <InlineState icon={Timer} title="Too many tries, wait a minute" {...actions}>
      <p>We paused for a moment to keep your account safe. Wait a minute, then try again.</p>
    </InlineState>
  );
}

/** A full-screen message outside the shell: the app is off, or access has ended. */
function FullScreenState({ icon, title, children, actions }: { icon: LucideIcon; title: string; children: ReactNode; actions: ReactNode }): ReactElement {
  useDocumentTitle(title);
  return (
    <main className="emp-auth">
      <div className="emp-auth-grow" role="alert">
        <StateIcon icon={icon} />
        <h1 className="emp-h1">{title}</h1>
        {children}
      </div>
      <div className="space-y-2">{actions}</div>
    </main>
  );
}

export function UnavailableScreen({ onRetry, onSignOut }: { onRetry?: () => void; onSignOut?: () => void }): ReactElement {
  const brand = useBrand();
  return (
    <FullScreenState icon={Power} title="The employee app isn't available right now" actions={<>
      {onRetry && (
        <EmpButton block onClick={onRetry}>
          <RefreshCw aria-hidden="true" className="size-6" />
          Try again
        </EmpButton>
      )}
      {onSignOut && <EmpButton block variant="quiet" onClick={onSignOut}>Sign out</EmpButton>}
    </>}>
      <p className="emp-lead">Your pay stubs still come the usual way.</p>
      <p className="text-neutral-600">{askManager(brand, 'Questions about your pay? Ask your manager')}</p>
    </FullScreenState>
  );
}

export function AccessEndedScreen({ onSignOut }: { onSignOut: () => void }): ReactElement {
  const brand = useBrand();
  return (
    <FullScreenState icon={Lock} title="Your access has ended" actions={
      <EmpButton block variant="secondary" onClick={onSignOut}>Sign out</EmpButton>
    }>
      <p className="emp-lead">You can't see pay stubs here anymore.</p>
      <p className="text-neutral-600">
        {brand.isFallback ? 'Need a copy of an old pay stub or tax form? Ask your employer.' : `Need a copy of an old pay stub or tax form? Ask ${brand.name}.`}
      </p>
    </FullScreenState>
  );
}

/** While sign-in and branding load. */
export function BootScreen(): ReactElement {
  return (
    <main className="emp-boot" aria-busy="true">
      <LoaderCircle aria-hidden="true" className="size-8 animate-spin text-neutral-400 motion-reduce:animate-none" />
      <span className="sr-only" role="status">Loading</span>
    </main>
  );
}
