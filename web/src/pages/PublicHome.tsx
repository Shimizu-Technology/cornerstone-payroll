import { ArrowRight, Building2, CheckCircle2, Landmark, Printer, ReceiptText, ShieldCheck } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';

const platformHighlights = [
  'Guam payroll workflows built around W-2GU, 941-GU, Form 500, and local DRT realities.',
  'Multi-client payroll operations for accounting firms, with firm-level tenant separation.',
  'Check printing, reports, time imports, client documents, transmittals, and invoice tools in one workspace.',
];

const featureBands = [
  {
    icon: <Landmark className="h-5 w-5" />,
    title: 'Guam-native payroll',
    body: 'Designed for Guam payroll and filing workflows instead of forcing mainland payroll assumptions into local operations.',
  },
  {
    icon: <Building2 className="h-5 w-5" />,
    title: 'Built for firms',
    body: 'Manage payroll clients, staff users, permissions, reports, and operational handoffs from a tenant-safe workspace.',
  },
  {
    icon: <Printer className="h-5 w-5" />,
    title: 'Practical operations',
    body: 'Run payroll, print checks, tune printer alignment, generate forms, and keep supporting records close to the work.',
  },
  {
    icon: <ReceiptText className="h-5 w-5" />,
    title: 'Always improving',
    body: 'Invoice tools, AI-assisted drafts, document workflows, and migration support are growing around the real work firms do.',
  },
];

export function PublicHome() {
  const { isAuthenticated, isLoading } = useAuth();

  return (
    <main className="min-h-screen bg-white text-neutral-950">
      <header className="border-b border-neutral-200 bg-white/95">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-5 py-4 sm:px-6 lg:px-8">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary-700 text-sm font-bold text-white">
              CP
            </div>
            <div>
              <p className="text-sm font-semibold leading-tight">Cornerstone Payroll</p>
              <p className="text-xs text-neutral-500">Built with Shimizu Technology</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {isLoading ? (
              <span className="inline-flex items-center justify-center rounded-xl px-3 py-1.5 text-xs font-medium text-neutral-500">
                Checking...
              </span>
            ) : isAuthenticated ? (
              <Link
                to="/app"
                className="inline-flex items-center justify-center rounded-xl bg-primary-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-primary-700"
              >
                Open App
              </Link>
            ) : (
              <Link
                to="/login"
                className="inline-flex items-center justify-center rounded-xl px-3 py-1.5 text-xs font-medium text-neutral-700 transition-colors hover:bg-neutral-100 hover:text-neutral-900"
              >
                Sign In
              </Link>
            )}
          </div>
        </div>
      </header>

      <section className="border-b border-neutral-200 bg-neutral-950 text-white">
        <div className="mx-auto grid min-h-[620px] max-w-7xl items-center gap-10 px-5 py-16 sm:px-6 lg:grid-cols-[minmax(0,1fr)_440px] lg:px-8">
          <div className="max-w-3xl">
            <p className="mb-5 inline-flex rounded-full border border-white/20 px-3 py-1 text-xs font-semibold uppercase tracking-[0.14em] text-emerald-200">
              Payroll software for Guam
            </p>
            <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl lg:text-6xl">
              QuickBooks was not built for Guam payroll. This is.
            </h1>
            <p className="mt-6 max-w-2xl text-base leading-8 text-neutral-300 sm:text-lg">
              Cornerstone Payroll is a Guam-native payroll platform built by Shimizu Technology in partnership with
              Cornerstone Accounting and Business Management. It supports payroll service work today and is growing
              into a platform other Guam accounting firms can use for their own clients.
            </p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <a
                href="https://shimizu-technology.com"
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center justify-center gap-2 rounded-lg bg-white px-5 py-3 text-sm font-semibold text-neutral-950 transition-colors hover:bg-neutral-100"
              >
                Platform Inquiries
                <ArrowRight className="h-4 w-4" />
              </a>
              <a
                href="https://cornerstone-accounting.tax"
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/25 px-5 py-3 text-sm font-semibold text-white transition-colors hover:bg-white/10"
              >
                Payroll Service Help
                <ArrowRight className="h-4 w-4" />
              </a>
            </div>
          </div>

          <div className="rounded-xl border border-white/15 bg-white/10 p-5 shadow-2xl shadow-black/30 backdrop-blur">
            <div className="rounded-lg bg-white p-5 text-neutral-950">
              <div className="flex items-center justify-between border-b border-neutral-200 pb-4">
                <div>
                  <p className="text-xs font-semibold uppercase tracking-[0.14em] text-neutral-500">Payroll Run</p>
                  <p className="mt-1 text-xl font-semibold">Guam client workspace</p>
                </div>
                <ShieldCheck className="h-8 w-8 text-emerald-700" />
              </div>
              <div className="mt-5 space-y-3">
                {platformHighlights.map((highlight) => (
                  <div key={highlight} className="flex gap-3 rounded-lg border border-neutral-200 bg-neutral-50 p-3">
                    <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" />
                    <p className="text-sm leading-6 text-neutral-700">{highlight}</p>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-neutral-200 bg-white px-5 py-16 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-7xl">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold tracking-tight text-neutral-950">For payroll teams that live in the details.</h2>
            <p className="mt-4 text-base leading-7 text-neutral-600">
              The product focuses on the ordinary work that has to be right: employee records, tax settings,
              pay periods, check stock, reports, client handoffs, and the paper trail around each payroll.
            </p>
          </div>
          <div className="mt-10 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            {featureBands.map((feature) => (
              <article key={feature.title} className="rounded-lg border border-neutral-200 bg-white p-5">
                <div className="mb-4 flex h-10 w-10 items-center justify-center rounded-lg bg-emerald-50 text-emerald-800">
                  {feature.icon}
                </div>
                <h3 className="text-base font-semibold text-neutral-950">{feature.title}</h3>
                <p className="mt-2 text-sm leading-6 text-neutral-600">{feature.body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="bg-neutral-50 px-5 py-14 sm:px-6 lg:px-8">
        <div className="mx-auto grid max-w-7xl gap-5 md:grid-cols-2">
          <div className="rounded-lg border border-neutral-200 bg-white p-6">
            <p className="text-sm font-semibold uppercase tracking-[0.12em] text-primary-700">Platform</p>
            <h2 className="mt-3 text-2xl font-semibold">Shimizu Technology</h2>
            <p className="mt-3 text-sm leading-6 text-neutral-600">
              Product, implementation, and platform inquiries for firms interested in Guam-native payroll software.
            </p>
            <div className="mt-5 space-y-2 text-sm text-neutral-700">
              <a
                href="https://shimizu-technology.com"
                target="_blank"
                rel="noreferrer"
                className="block transition-colors hover:text-primary-700 hover:underline"
              >
                shimizu-technology.com
              </a>
              <p>671-483-0219</p>
            </div>
          </div>
          <div className="rounded-lg border border-neutral-200 bg-white p-6">
            <p className="text-sm font-semibold uppercase tracking-[0.12em] text-primary-700">Payroll Services</p>
            <h2 className="mt-3 text-2xl font-semibold">Cornerstone Accounting and Business Management</h2>
            <p className="mt-3 text-sm leading-6 text-neutral-600">
              Payroll and accounting service inquiries for businesses that want help operating payroll in Guam.
            </p>
            <div className="mt-5 space-y-2 text-sm text-neutral-700">
              <a
                href="https://cornerstone-accounting.tax"
                target="_blank"
                rel="noreferrer"
                className="block transition-colors hover:text-primary-700 hover:underline"
              >
                cornerstone-accounting.tax
              </a>
              <p>671-482-8671</p>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
