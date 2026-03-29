import { SignIn } from '@clerk/clerk-react';
import { ShieldCheck, Clock3, Landmark } from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { Card, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

const highlights = [
  {
    title: 'Guam-first payroll compliance',
    description: 'Built for W-2GU, 941-GU, and local filing workflows.',
    icon: <Landmark className="h-5 w-5" />,
  },
  {
    title: 'Secure operational controls',
    description: 'Role-based access and audit visibility for every workflow.',
    icon: <ShieldCheck className="h-5 w-5" />,
  },
  {
    title: 'Faster payroll execution',
    description: 'Run periods, print checks, and generate reports from one workspace.',
    icon: <Clock3 className="h-5 w-5" />,
  },
];

export function Login() {
  const { isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-transparent">
        <p className="text-sm text-neutral-500">Loading Cornerstone Payroll...</p>
      </div>
    );
  }

  if (!clerkPubKey) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-transparent px-4">
        <Card className="w-full max-w-xl">
          <CardHeader className="text-center">
            <CardTitle className="text-xl">Cornerstone Payroll</CardTitle>
            <CardDescription>
              Clerk is not configured in <code>web/.env</code>. Add <code>VITE_CLERK_PUBLISHABLE_KEY</code> to enable sign in.
            </CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-transparent px-4 py-10 lg:px-8">
      <div className="mx-auto grid w-full max-w-6xl gap-8 lg:grid-cols-2">
        <section className="relative overflow-hidden rounded-3xl border border-neutral-200/80 bg-gradient-to-br from-primary-950 via-primary-900 to-primary-700 p-8 text-white shadow-xl shadow-primary-900/20 lg:p-10">
          <div className="absolute right-0 top-0 h-56 w-56 translate-x-1/3 -translate-y-1/3 rounded-full bg-white/10 blur-2xl" />
          <div className="absolute bottom-0 left-0 h-52 w-52 -translate-x-1/4 translate-y-1/3 rounded-full bg-success-500/20 blur-2xl" />

          <div className="relative">
            <div className="mb-8 inline-flex items-center gap-3 rounded-2xl border border-white/20 bg-white/10 px-4 py-2 backdrop-blur-sm">
              <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-white/20 font-bold">CP</div>
              <span className="text-sm font-semibold tracking-tight">Cornerstone Payroll</span>
            </div>

            <h1 className="max-w-md text-3xl font-semibold leading-tight tracking-tight lg:text-4xl">
              Payroll operations built for Guam teams.
            </h1>
            <p className="mt-4 max-w-lg text-sm leading-relaxed text-primary-100 lg:text-base">
              A dedicated payroll workspace for Cornerstone Tax Services: company setup, employee records, pay periods,
              check printing, and year-end reporting.
            </p>

            <div className="mt-10 space-y-4">
              {highlights.map((item) => (
                <div
                  key={item.title}
                  className="flex items-start gap-3 rounded-2xl border border-white/15 bg-white/10 p-4 backdrop-blur-sm"
                >
                  <div className="mt-0.5 rounded-lg bg-white/20 p-2 text-white">{item.icon}</div>
                  <div>
                    <p className="text-sm font-semibold">{item.title}</p>
                    <p className="mt-1 text-sm text-primary-100/95">{item.description}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-neutral-200/80 bg-white/90 p-6 shadow-xl shadow-neutral-200/50 backdrop-blur-sm lg:p-8">
          <div className="mb-6">
            <p className="text-xs font-semibold uppercase tracking-[0.14em] text-primary-700">Welcome back</p>
            <h2 className="mt-2 text-2xl font-semibold tracking-tight text-neutral-900">Sign in to Cornerstone Payroll</h2>
            <p className="mt-2 text-sm text-neutral-500">Use your staff account to continue.</p>
          </div>

          <SignIn
            routing="hash"
            appearance={{
              elements: {
                rootBox: 'mx-auto w-full',
                card: 'shadow-none border border-neutral-200 rounded-2xl',
                headerTitle: 'text-neutral-900',
                headerSubtitle: 'text-neutral-500',
                socialButtonsBlockButton:
                  'rounded-xl border-neutral-200 hover:bg-neutral-50 transition-colors',
                formButtonPrimary:
                  'rounded-xl bg-primary-600 hover:bg-primary-700 text-white shadow-sm transition-colors',
                formFieldInput:
                  'rounded-xl border-neutral-300 focus:border-primary-500 focus:ring-primary-200',
                footerActionLink: 'text-primary-700 hover:text-primary-800',
              },
            }}
          />
        </section>
      </div>
    </div>
  );
}
