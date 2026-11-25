import type { ReactNode } from 'react';
import { SignIn, useAuth } from '@clerk/react';
import { Button } from '@/components/ui/button';
import { getApiBaseUrl } from '@/services/api';
import { useSupportView } from './useSupportView';

export function ClientSupportView({ children }: { children: ReactNode }) {
  const { isLoaded, isSignedIn, getToken, sessionId } = useAuth();
  if (!isLoaded) return <p className="p-6" role="status">Loading support view…</p>;
  if (!isSignedIn) return (
    <main className="grid min-h-screen place-content-center gap-4 p-4">
      <h1 className="font-semibold">Sign in with your staff account</h1>
      <SignIn routing="hash" withSignUp={false} forceRedirectUrl="/app" />
    </main>
  );
  return <ClientGrant key={sessionId} getToken={getToken}>{children}</ClientGrant>;
}

export function ClientGrant({ getToken, children }: { getToken: () => Promise<string | null>; children: ReactNode }) {
  const { grant, loadError, endError, ending, end, retry, leave } = useSupportView(getApiBaseUrl(), getToken, '/app');

  if (!grant) return (
    <main className="mx-auto max-w-lg space-y-4 p-6">
      <p role="status">{loadError ?? 'Loading support view…'}</p>
      {loadError && <div className="flex flex-wrap gap-2">
        <Button variant="outline" onClick={retry}>Try again</Button>
        <Button onClick={leave}>Return to payroll</Button>
      </div>}
    </main>
  );

  return (
    <div className="flex h-dvh min-h-0 flex-col [&>div:last-child]:min-h-0 [&>div:last-child]:flex-1">
      <section aria-label="View only" className="relative z-40 shrink-0 border-b border-amber-300 bg-amber-50 px-4 py-2 text-amber-950">
        <div className="flex items-center justify-between gap-3">
          <p className="min-w-0 break-words text-sm font-semibold">Viewing as {grant.name}, view only</p>
          <Button variant="outline" className="shrink-0" onClick={() => void end()} disabled={ending}>
            {ending ? 'Ending…' : 'End'}
          </Button>
        </div>
        {endError && <p role="alert" className="mt-1 text-sm">{endError}</p>}
      </section>
      {children}
    </div>
  );
}
