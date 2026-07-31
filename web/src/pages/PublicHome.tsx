import {
  ArrowRight,
  Building2,
  CheckCircle2,
  FileCheck2,
  Landmark,
  LockKeyhole,
  Printer,
  ReceiptText,
  ShieldCheck,
  Users2,
} from 'lucide-react';
import { Link } from 'react-router';
import { useAuth } from '@/contexts/AuthContext';

const runSteps = [
  { label: 'Client ready', detail: 'Company, employees, tax profile', icon: <Building2 className="h-4 w-4" />, status: 'Complete' },
  { label: 'Payroll in review', detail: 'Hours, deductions, checks', icon: <ReceiptText className="h-4 w-4" />, status: 'Active' },
  { label: 'Filing packet', detail: 'Guam reports and DRT support', icon: <FileCheck2 className="h-4 w-4" />, status: 'Next' },
];

const proofPoints = [
  { value: 'W-2GU', label: 'Guam wage reporting' },
  { value: 'Form 941', label: 'Federal quarterly workflow' },
  { value: 'Firm-ready', label: 'Multi-client operations' },
];

const featureBands = [
  {
    icon: <Landmark className="h-5 w-5" />,
    title: 'Guam-native compliance',
    body: 'Built around W-2GU, Federal Form 941, Form 500, SWICA, and the distinct IRS and Guam DRT workflows employers actually use.',
  },
  {
    icon: <Users2 className="h-5 w-5" />,
    title: 'Client payroll workspace',
    body: 'Switch between payroll clients, manage employee records, collect documents, and keep staff handoffs consistent.',
  },
  {
    icon: <Printer className="h-5 w-5" />,
    title: 'Checks, reports, and records',
    body: 'Check alignment, reprints, voids, replacements, signoff sheets, registers, and supporting exports stay tied to the period.',
  },
  {
    icon: <LockKeyhole className="h-5 w-5" />,
    title: 'Controlled access',
    body: 'Role-based staff and client portal experiences keep payroll data, documents, and operational actions in the right hands.',
  },
];

export function PublicHome() {
  const { isAuthenticated, isLoading } = useAuth();

  return (
    <main className="min-h-screen bg-[#f8f6f1] text-neutral-950">
      <header className="sticky top-0 z-20 border-b border-neutral-900/10 bg-[#f8f6f1]/90 backdrop-blur-xl">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-5 py-3.5 sm:px-6 lg:px-8">
          <Link to="/" className="flex items-center gap-3 rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
            <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-950 text-sm font-extrabold text-white shadow-lg shadow-primary-950/15">
              CP
            </div>
            <div>
              <p className="font-display text-sm font-extrabold leading-tight tracking-tight">Cornerstone Payroll</p>
              <p className="text-xs font-medium text-neutral-500">Guam payroll operations</p>
            </div>
          </Link>

          <nav className="hidden items-center gap-7 text-sm font-semibold text-neutral-600 md:flex" aria-label="Primary navigation">
            <a href="#workflow" className="transition-colors hover:text-primary-800">Workflow</a>
            <a href="#features" className="transition-colors hover:text-primary-800">Features</a>
            <a href="#contact" className="transition-colors hover:text-primary-800">Contact</a>
          </nav>

          <div className="flex items-center gap-2">
            {isLoading ? (
              <span className="inline-flex items-center justify-center rounded-full px-3 py-1.5 text-xs font-semibold text-neutral-500">
                Checking access
              </span>
            ) : isAuthenticated ? (
              <Link
                to="/app"
                className="inline-flex items-center justify-center rounded-full bg-primary-950 px-4 py-2 text-xs font-bold text-white transition-all hover:-translate-y-0.5 hover:bg-primary-800"
              >
                Open App
              </Link>
            ) : (
              <Link
                to="/login"
                className="inline-flex items-center justify-center rounded-full border border-neutral-300 bg-white/75 px-4 py-2 text-xs font-bold text-neutral-800 transition-all hover:-translate-y-0.5 hover:border-primary-300 hover:text-primary-800"
              >
                Sign In
              </Link>
            )}
          </div>
        </div>
      </header>

      <section className="relative overflow-hidden border-b border-neutral-900/10">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_12%_10%,rgba(29,95,210,0.14),transparent_31%),radial-gradient(circle_at_88%_10%,rgba(244,127,11,0.13),transparent_28%),linear-gradient(180deg,rgba(255,255,255,0.22),rgba(255,255,255,0.74))]" />
        <div className="relative mx-auto grid min-h-[620px] max-w-7xl items-center gap-12 px-5 py-16 sm:px-6 lg:grid-cols-[minmax(0,1.03fr)_minmax(420px,0.72fr)] lg:px-8 lg:py-20">
          <div className="max-w-3xl">
            <p className="mb-5 inline-flex rounded-full border border-primary-200 bg-white/80 px-3.5 py-1.5 text-xs font-extrabold uppercase tracking-[0.16em] text-primary-900 shadow-sm shadow-primary-100/60">
              Payroll software for Guam firms
            </p>
            <h1 className="font-display text-4xl font-extrabold leading-[1.02] tracking-tight text-primary-950 text-balance sm:text-5xl lg:text-6xl">
              Guam payroll, organized from pay run to filing.
            </h1>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-neutral-700">
              A clean payroll workspace for accounting teams that need local compliance, check printing, client handoffs,
              and audit-ready records without forcing Guam workflows through mainland payroll software.
            </p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <a
                href="https://shimizu-technology.com"
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center justify-center gap-2 rounded-full bg-primary-950 px-6 py-3 text-sm font-bold text-white shadow-xl shadow-primary-950/15 transition-all hover:-translate-y-0.5 hover:bg-primary-800"
              >
                Platform Inquiries
                <ArrowRight className="h-4 w-4" />
              </a>
              <a
                href="https://cornerstone-accounting.tax"
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center justify-center gap-2 rounded-full border border-neutral-300 bg-white/75 px-6 py-3 text-sm font-bold text-neutral-900 transition-all hover:-translate-y-0.5 hover:border-primary-300 hover:text-primary-800"
              >
                Payroll Service Help
                <ArrowRight className="h-4 w-4" />
              </a>
            </div>

            <div className="mt-10 grid max-w-2xl gap-3 sm:grid-cols-3" aria-label="Platform highlights">
              {proofPoints.map((point) => (
                <div key={point.value} className="rounded-2xl border border-white/80 bg-white/65 px-4 py-3 shadow-sm shadow-neutral-200/50 backdrop-blur-sm">
                  <p className="font-display text-lg font-extrabold text-primary-950">{point.value}</p>
                  <p className="mt-1 text-xs font-semibold leading-4 text-neutral-500">{point.label}</p>
                </div>
              ))}
            </div>
          </div>

          <div className="relative">
            <div className="absolute -inset-5 rounded-[2.25rem] bg-white/45 blur-2xl" />
            <div className="relative rounded-[2rem] border border-white/85 bg-white/78 p-4 shadow-2xl shadow-primary-950/10 backdrop-blur-xl">
              <div className="rounded-[1.45rem] border border-neutral-200/70 bg-white p-5">
                <div className="flex items-start justify-between gap-4 border-b border-neutral-200 pb-5">
                  <div>
                    <p className="text-xs font-extrabold uppercase tracking-[0.16em] text-primary-700">Today’s payroll desk</p>
                    <h2 className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">Pay period review</h2>
                    <p className="mt-1 text-sm text-neutral-500">MoSa Hospitality • Biweekly payroll</p>
                  </div>
                  <div className="rounded-2xl bg-success-50 p-2.5 text-success-600 ring-1 ring-success-100">
                    <ShieldCheck className="h-5 w-5" />
                  </div>
                </div>

                <div className="mt-5 grid grid-cols-3 gap-3">
                  <div className="rounded-2xl bg-primary-50 p-3 ring-1 ring-primary-100">
                    <p className="text-xs font-semibold text-primary-700">Employees</p>
                    <p className="mt-1 font-display text-2xl font-extrabold text-primary-950">48</p>
                  </div>
                  <div className="rounded-2xl bg-accent-50 p-3 ring-1 ring-accent-100">
                    <p className="text-xs font-semibold text-accent-700">Checks</p>
                    <p className="mt-1 font-display text-2xl font-extrabold text-primary-950">42</p>
                  </div>
                  <div className="rounded-2xl bg-success-50 p-3 ring-1 ring-success-100">
                    <p className="text-xs font-semibold text-success-700">Status</p>
                    <p className="mt-1 font-display text-xl font-extrabold text-primary-950">Review</p>
                  </div>
                </div>

                <div id="workflow" className="mt-5 space-y-3">
                  {runSteps.map((item) => (
                    <div key={item.label} className="flex items-center gap-4 rounded-2xl border border-neutral-200 bg-neutral-50/80 p-4">
                      <div className="flex h-9 w-9 items-center justify-center rounded-full bg-white text-primary-800 shadow-sm ring-1 ring-neutral-200">
                        {item.icon}
                      </div>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <p className="text-sm font-bold text-neutral-950">{item.label}</p>
                          <span className="rounded-full bg-white px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-[0.12em] text-neutral-500 ring-1 ring-neutral-200">
                            {item.status}
                          </span>
                        </div>
                        <p className="mt-1 text-sm text-neutral-500">{item.detail}</p>
                      </div>
                    </div>
                  ))}
                </div>

                <div className="mt-5 rounded-2xl bg-primary-950 p-4 text-white">
                  <div className="flex items-center gap-3">
                    <CheckCircle2 className="h-5 w-5 text-accent-200" />
                    <p className="text-sm font-bold">Quarterly packet ready for firm review</p>
                  </div>
                  <p className="mt-2 text-sm leading-6 text-primary-100/82">
                    Registers, withholding, check records, and Guam filing documents stay close to the pay period.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section id="features" className="bg-white px-5 py-18 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-7xl">
          <div className="grid gap-8 lg:grid-cols-[0.85fr_1.15fr] lg:items-end">
            <div>
              <p className="text-xs font-extrabold uppercase tracking-[0.16em] text-primary-700">Built for the real desk work</p>
              <h2 className="mt-3 font-display text-3xl font-extrabold tracking-tight text-neutral-950 text-balance lg:text-4xl">
                Professional payroll software should make the next step obvious.
              </h2>
            </div>
            <p className="max-w-2xl text-base leading-7 text-neutral-600 lg:justify-self-end">
              The product is organized around the operational sequence payroll teams actually follow: maintain records,
              run the period, issue checks, export reports, and share supporting documents.
            </p>
          </div>

          <div className="mt-10 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            {featureBands.map((feature) => (
              <article key={feature.title} className="rounded-[1.35rem] border border-neutral-200 bg-white p-5 shadow-sm shadow-neutral-200/60 transition-all hover:-translate-y-1 hover:border-primary-200">
                <div className="mb-5 flex h-11 w-11 items-center justify-center rounded-2xl bg-primary-50 text-primary-800 ring-1 ring-primary-100">
                  {feature.icon}
                </div>
                <h3 className="font-display text-base font-extrabold text-neutral-950">{feature.title}</h3>
                <p className="mt-2 text-sm leading-6 text-neutral-600">{feature.body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section id="contact" className="bg-primary-950 px-5 py-14 text-white sm:px-6 lg:px-8">
        <div className="mx-auto grid max-w-7xl gap-5 md:grid-cols-2">
          <div className="rounded-[1.35rem] border border-white/10 bg-white/[0.06] p-6">
            <p className="text-xs font-extrabold uppercase tracking-[0.16em] text-accent-200">Platform</p>
            <h2 className="mt-3 font-display text-2xl font-extrabold">Shimizu Technology</h2>
            <p className="mt-3 text-sm leading-6 text-primary-100/80">
              Product, implementation, and platform inquiries for firms interested in Guam-native payroll software.
            </p>
            <div className="mt-5 space-y-2 text-sm font-semibold text-white">
              <a href="https://shimizu-technology.com" target="_blank" rel="noreferrer" className="block transition-colors hover:text-accent-200">
                shimizu-technology.com
              </a>
              <p>671-483-0219</p>
            </div>
          </div>
          <div className="rounded-[1.35rem] border border-white/10 bg-white/[0.06] p-6">
            <p className="text-xs font-extrabold uppercase tracking-[0.16em] text-accent-200">Payroll Services</p>
            <h2 className="mt-3 font-display text-2xl font-extrabold">Cornerstone Accounting and Business Management</h2>
            <p className="mt-3 text-sm leading-6 text-primary-100/80">
              Payroll and accounting service inquiries for businesses that want help operating payroll in Guam.
            </p>
            <div className="mt-5 space-y-2 text-sm font-semibold text-white">
              <a href="https://cornerstone-accounting.tax" target="_blank" rel="noreferrer" className="block transition-colors hover:text-accent-200">
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
