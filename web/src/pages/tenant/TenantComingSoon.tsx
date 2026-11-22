import { useEffect, useState } from 'react';
import api, { type TenantBranding } from '@/services/api';

export function TenantComingSoon({ host }: { host: string }) {
  const [branding, setBranding] = useState<TenantBranding | null>();
  const [requestFailed, setRequestFailed] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    async function loadBranding() {
      try {
        const data = await api.getTenantBranding(host, controller.signal);
        if (!controller.signal.aborted) setBranding(data);
      } catch {
        if (!controller.signal.aborted) setRequestFailed(true);
      }
    }

    void loadBranding();
    return () => controller.abort();
  }, [host]);

  useEffect(() => {
    document.title = branding ? `${branding.name} | Employee Portal` : 'Employee Portal';
  }, [branding]);

  const unavailable = requestFailed || branding === null;
  const heading = branding ? 'Employee portal coming soon' : unavailable ? 'Employee portal unavailable' : 'Loading employee portal';

  return (
    <main
      className="grid min-h-svh place-items-center bg-neutral-50 px-4 py-10"
      style={{ borderTop: `4px solid ${branding?.primary_color ?? 'var(--color-primary-800)'}` }}
    >
      <section className="w-full max-w-lg overflow-hidden rounded-2xl border border-neutral-200 bg-white px-6 py-10 text-center shadow-sm sm:px-10">
        {branding?.logo_url && (
          <img
            src={branding.logo_url}
            alt=""
            referrerPolicy="no-referrer"
            className="mx-auto mb-5 h-16 max-w-full object-contain"
            onError={(event) => { event.currentTarget.hidden = true; }}
          />
        )}
        {branding && (
          <>
            <p className="break-words text-lg font-semibold text-neutral-800">{branding.name}</p>
            <div
              aria-hidden="true"
              className="mx-auto my-5 h-1 w-10 rounded-full"
              style={{ backgroundColor: branding.accent_color ?? 'var(--color-accent-400)' }}
            />
          </>
        )}
        <div role="status">
          <h1 className="text-2xl font-bold text-neutral-950">{heading}</h1>
          {(branding || unavailable) && (
            <p className="mt-3 text-neutral-700">
              {branding ? 'Your employer will let you know when the portal is ready. ' : ''}
              Please contact your employer if you need help.
            </p>
          )}
        </div>
        {branding && <footer className="mt-8 text-sm text-neutral-600">Powered by Cornerstone Payroll</footer>}
      </section>
    </main>
  );
}
