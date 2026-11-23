import { useEffect, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router';

export const LEGAL_LAST_UPDATED = 'November 23, 2026';

interface LegalLayoutProps {
  title: string;
  intro: ReactNode;
  children: ReactNode;
}

const footerLinks = [
  { to: '/', label: 'Home' },
  { to: '/privacy', label: 'Privacy Policy' },
  { to: '/terms', label: 'Terms of Service' },
];

export function LegalLayout({ title, intro, children }: LegalLayoutProps) {
  const { pathname } = useLocation();

  useEffect(() => {
    const previous = document.title;
    document.title = `${title} · Cornerstone Payroll`;
    return () => { document.title = previous; };
  }, [title]);

  return (
    <div className="min-h-screen bg-[#f8f6f1] text-neutral-950">
      <header className="border-b border-neutral-900/10 bg-[#f8f6f1]/90">
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-4 px-5 py-3.5 sm:px-6">
          <Link to="/" className="flex items-center gap-3 rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
            <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-950 text-sm font-extrabold text-white">
              CP
            </div>
            <p className="font-display text-sm font-extrabold leading-tight tracking-tight">Cornerstone Payroll</p>
          </Link>
          <Link to="/login" className="text-sm font-bold text-primary-800 underline-offset-4 hover:underline">
            Sign in
          </Link>
        </div>
      </header>

      <main>
        <article className="mx-auto max-w-3xl px-5 py-10 sm:px-6 sm:py-14">
          <h1 className="font-display text-3xl font-extrabold tracking-tight text-primary-950 sm:text-4xl">{title}</h1>
          <p className="mt-3 text-sm font-semibold text-neutral-500">Last updated {LEGAL_LAST_UPDATED}</p>
          <div className="mt-6 text-base leading-7 text-neutral-800">{intro}</div>
          <div className="mt-8 space-y-9 text-base leading-7 text-neutral-800">{children}</div>
        </article>
      </main>

      <footer className="border-t border-neutral-900/10">
        <nav aria-label="Legal" className="mx-auto flex max-w-3xl flex-wrap gap-x-6 gap-y-2 px-5 py-6 text-sm font-semibold text-neutral-600 sm:px-6">
          {footerLinks.map(link => (
            <Link
              key={link.to}
              to={link.to}
              aria-current={pathname === link.to ? 'page' : undefined}
              className="hover:text-primary-800 aria-[current=page]:text-primary-900"
            >
              {link.label}
            </Link>
          ))}
        </nav>
      </footer>
    </div>
  );
}

export function LegalSection({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} aria-labelledby={`${id}-title`} className="scroll-mt-6">
      <h2 id={`${id}-title`} className="font-display text-xl font-extrabold tracking-tight text-primary-950">{title}</h2>
      <div className="mt-3 space-y-4">{children}</div>
    </section>
  );
}

export function LegalList({ children }: { children: ReactNode }) {
  return <ul className="list-disc space-y-2 pl-6 marker:text-primary-700">{children}</ul>;
}
