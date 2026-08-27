import { Component, lazy, Suspense, useEffect, type ErrorInfo, type ReactNode } from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router';
import { ClerkProvider } from '@clerk/clerk-react';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { CompanyProvider } from '@/contexts/CompanyContext';
import { PostHogPageView, usePostHog, isPostHogEnabled } from '@/providers/PostHogProvider';
import { Layout } from '@/components/layout/Layout';
import { CompanyScopedRoute } from '@/components/routing/CompanyScopedRoute';
import { LegacyCompanyRedirect } from '@/components/routing/LegacyCompanyRedirect';

const Dashboard = lazy(() => import('@/pages/Dashboard').then((module) => ({ default: module.Dashboard })));
const EmployeeList = lazy(() => import('@/pages/employees/EmployeeList').then((module) => ({ default: module.EmployeeList })));
const EmployeeForm = lazy(() => import('@/pages/employees/EmployeeForm').then((module) => ({ default: module.EmployeeForm })));
const EmployeeWorkspace = lazy(() => import('@/pages/employees/EmployeeWorkspace').then((module) => ({ default: module.EmployeeWorkspace })));
const Departments = lazy(() => import('@/pages/Departments').then((module) => ({ default: module.Departments })));
const PayPeriods = lazy(() => import('@/pages/PayPeriods').then((module) => ({ default: module.PayPeriods })));
const PayRunWorkspace = lazy(() => import('@/pages/pay-periods/PayRunWorkspace').then((module) => ({ default: module.PayRunWorkspace })));
const PayrollItemDetail = lazy(() => import('@/pages/payroll-items/PayrollItemDetail').then((module) => ({ default: module.PayrollItemDetail })));
const Reports = lazy(() => import('@/pages/Reports').then((module) => ({ default: module.Reports })));
const ChecksPayments = lazy(() => import('@/pages/ChecksPayments').then((module) => ({ default: module.ChecksPayments })));
const ClientDashboard = lazy(() => import('@/pages/client/ClientDashboard').then((module) => ({ default: module.ClientDashboard })));
const ClientPayPeriods = lazy(() => import('@/pages/client/ClientPayPeriods').then((module) => ({ default: module.ClientPayPeriods })));
const ClientPayPeriodDetail = lazy(() => import('@/pages/client/ClientPayPeriodDetail').then((module) => ({ default: module.ClientPayPeriodDetail })));
const ClientReports = lazy(() => import('@/pages/client/ClientReports').then((module) => ({ default: module.ClientReports })));
const ClientDocuments = lazy(() => import('@/pages/client/ClientDocuments').then((module) => ({ default: module.ClientDocuments })));
const ClientChangeRequests = lazy(() => import('@/pages/client/ClientChangeRequests').then((module) => ({ default: module.ClientChangeRequests })));
const Form500Page = lazy(() => import('@/pages/Form500Page').then((module) => ({ default: module.Form500Page })));
const AdminClientDocumentsPage = lazy(() => import('@/pages/AdminClientDocumentsPage').then((module) => ({ default: module.AdminClientDocumentsPage })));
const AdminEmployeeChangeRequestsPage = lazy(() => import('@/pages/AdminEmployeeChangeRequestsPage').then((module) => ({ default: module.AdminEmployeeChangeRequestsPage })));
const TaxConfigs = lazy(() => import('@/pages/TaxConfigs'));
const Users = lazy(() => import('@/pages/Users').then((module) => ({ default: module.Users })));
const Organizations = lazy(() => import('@/pages/Organizations').then((module) => ({ default: module.Organizations })));
const AuditLogs = lazy(() => import('@/pages/AuditLogs').then((module) => ({ default: module.AuditLogs })));
const CheckSettingsPage = lazy(() => import('@/pages/CheckSettings').then((module) => ({ default: module.CheckSettingsPage })));
const EmployeeLoans = lazy(() => import('@/pages/EmployeeLoans'));
const PayrollFields = lazy(() => import('@/pages/PayrollFields'));
const Clients = lazy(() => import('@/pages/Clients').then((module) => ({ default: module.Clients })));
const TimecardOcrTool = lazy(() => import('@/pages/TimecardOcrTool').then((module) => ({ default: module.TimecardOcrTool })));
const GeneralTransmittals = lazy(() => import('@/pages/GeneralTransmittals').then((module) => ({ default: module.GeneralTransmittals })));
const InvoiceMaker = lazy(() => import('@/pages/InvoiceMaker').then((module) => ({ default: module.InvoiceMaker })));
const InvoiceCenter = lazy(() => import('@/pages/InvoiceCenter').then((module) => ({ default: module.InvoiceCenter })));
const PayrollReminders = lazy(() => import('@/pages/PayrollReminders'));
const TimeTrackingSources = lazy(() => import('@/pages/TimeTrackingSources').then((module) => ({ default: module.TimeTrackingSources })));
const PayScheduleSettings = lazy(() => import('@/pages/PayScheduleSettings').then((module) => ({ default: module.PayScheduleSettings })));
const Login = lazy(() => import('@/pages/Login').then((module) => ({ default: module.Login })));
const Invite = lazy(() => import('@/pages/Invite').then((module) => ({ default: module.Invite })));
const PublicHome = lazy(() => import('@/pages/PublicHome').then((module) => ({ default: module.PublicHome })));

// Environment flag to bypass auth in development
const AUTH_ENABLED = import.meta.env.VITE_AUTH_ENABLED === 'true';

// Protected route wrapper
function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();

  // Skip auth check if disabled
  if (!AUTH_ENABLED) {
    return <>{children}</>;
  }

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center">
          <svg className="animate-spin h-8 w-8 text-primary-600 mx-auto" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
          </svg>
          <p className="mt-4 text-gray-500">Loading...</p>
        </div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }

  return <>{children}</>;
}

function AdminOnlyRoute({ children }: { children: React.ReactNode }) {
  const { isAdmin, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center">
          <svg className="animate-spin h-8 w-8 text-primary-600 mx-auto" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
          </svg>
          <p className="mt-4 text-gray-500">Loading...</p>
        </div>
      </div>
    );
  }

  if (!isAdmin) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function ManagerOnlyRoute({ children }: { children: React.ReactNode }) {
  const { isManager, isLoading } = useAuth();

  if (isLoading) {
    return <PageLoader />;
  }

  if (!isManager) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function SuperAdminOnlyRoute({ children }: { children: React.ReactNode }) {
  const { isSuperAdmin, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center">
          <svg className="animate-spin h-8 w-8 text-primary-600 mx-auto" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
          </svg>
          <p className="mt-4 text-gray-500">Loading...</p>
        </div>
      </div>
    );
  }

  if (!isSuperAdmin) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function StaffOnlyRoute({ children }: { children: React.ReactNode }) {
  const { isClient, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center">
          <svg className="animate-spin h-8 w-8 text-primary-600 mx-auto" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
          </svg>
          <p className="mt-4 text-gray-500">Loading...</p>
        </div>
      </div>
    );
  }

  if (isClient) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function ClientOnlyRoute({ children }: { children: React.ReactNode }) {
  const { isClient, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center">
          <svg className="animate-spin h-8 w-8 text-primary-600 mx-auto" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
          </svg>
          <p className="mt-4 text-gray-500">Loading...</p>
        </div>
      </div>
    );
  }

  if (!isClient) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function PostHogIdentify() {
  const { user } = useAuth();
  const posthog = usePostHog();

  useEffect(() => {
    if (!isPostHogEnabled || !posthog) return;
    if (user) {
      posthog.identify(String(user.id), {
        email: user.email,
        name: user.name,
        role: user.role,
        company_id: user.company_id,
      });
    } else {
      posthog.reset();
    }
  }, [user, posthog]);

  return null;
}

function PageLoader() {
  return (
    <div className="flex min-h-[320px] items-center justify-center px-6 py-12">
      <div className="inline-flex items-center gap-3 rounded-full border border-neutral-200 bg-white/85 px-4 py-2 text-sm font-medium text-neutral-600 shadow-sm shadow-neutral-200/70">
        <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-primary-600" />
        Loading workspace
      </div>
    </div>
  );
}

class RouteErrorBoundary extends Component<{ children: ReactNode }, { hasError: boolean }> {
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('Route render failed:', error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex min-h-screen items-center justify-center bg-neutral-50 px-4 py-12">
          <div className="max-w-md rounded-[1.35rem] border border-neutral-200 bg-white p-6 text-center shadow-[0_18px_45px_-32px_rgba(15,23,42,0.45)]">
            <p className="text-xs font-bold uppercase tracking-[0.16em] text-primary-700">Cornerstone Payroll</p>
            <h1 className="mt-3 font-display text-2xl font-extrabold tracking-tight text-neutral-950">Something went wrong</h1>
            <p className="mt-2 text-sm leading-6 text-neutral-500">
              Refresh the page to reload the workspace. If this keeps happening, contact support with the page you were opening.
            </p>
            <button
              type="button"
              onClick={() => window.location.reload()}
              className="mt-5 inline-flex items-center justify-center rounded-full bg-primary-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-primary-800"
            >
              Reload page
            </button>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

function AppRoutes() {
  const { isClient } = useAuth();

  return (
    <RouteErrorBoundary>
      <Suspense fallback={<PageLoader />}>
        <Routes>
      {/* Public routes */}
      <Route path="/" element={<PublicHome />} />
      <Route path="/login" element={<Login />} />
      <Route path="/invite" element={<Invite />} />
      <Route path="/callback" element={<Navigate to="/app" replace />} />

      {/* Protected routes */}
      <Route
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route path="/app" element={isClient ? <ClientDashboard /> : <Dashboard />} />
        <Route path="employees" element={<LegacyCompanyRedirect destination="employees" />} />
        <Route path="employees/new" element={<LegacyCompanyRedirect destination="new-employee" />} />
        <Route path="employees/:id" element={<LegacyCompanyRedirect destination="employee" clientMode={isClient} />} />
        <Route path="departments" element={<Departments />} />
        <Route path="pay-periods" element={<LegacyCompanyRedirect destination="pay-runs" />} />
        <Route path="pay-periods/:id" element={<LegacyCompanyRedirect destination="pay-run" clientMode={isClient} />} />
        <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
          <Route path="employees" element={<EmployeeList />} />
          <Route path="employees/new" element={<EmployeeForm />} />
          <Route path="employees/:id/edit" element={<EmployeeForm />} />
          <Route path="employees/:id/:tab?" element={isClient ? <EmployeeForm /> : <EmployeeWorkspace />} />
          <Route path="pay-runs" element={isClient ? <ClientPayPeriods /> : <PayPeriods />} />
          <Route path="pay-runs/:id/payroll-items/:payrollItemId" element={<StaffOnlyRoute><PayrollItemDetail /></StaffOnlyRoute>} />
          {isClient && <Route path="pay-runs/:id/work" element={<ClientPayPeriodDetail />} />}
          <Route path="pay-runs/:id/:tab?" element={isClient ? <ClientPayPeriodDetail /> : <PayRunWorkspace />} />
        </Route>
        <Route path="checks-payments" element={<StaffOnlyRoute><ChecksPayments /></StaffOnlyRoute>} />
        <Route path="pay-periods/:id/form-500" element={<StaffOnlyRoute><Form500Page /></StaffOnlyRoute>} />
        <Route path="payroll/run" element={<Navigate to="/pay-periods" replace />} />
        <Route path="reports" element={isClient ? <ClientReports /> : <Reports />} />
        <Route path="documents" element={<ClientOnlyRoute><ClientDocuments /></ClientOnlyRoute>} />
        <Route path="change-requests" element={<ClientOnlyRoute><ClientChangeRequests /></ClientOnlyRoute>} />
        <Route path="employee-loans" element={<StaffOnlyRoute><EmployeeLoans /></StaffOnlyRoute>} />
        <Route path="payroll-fields" element={<ManagerOnlyRoute><PayrollFields /></ManagerOnlyRoute>} />
        <Route path="tools/timecard-ocr" element={<StaffOnlyRoute><TimecardOcrTool /></StaffOnlyRoute>} />
        <Route path="tools/transmittals" element={<StaffOnlyRoute><GeneralTransmittals /></StaffOnlyRoute>} />
        <Route path="tools/invoices" element={<AdminOnlyRoute><InvoiceCenter /></AdminOnlyRoute>} />
        <Route path="tools/invoices/assistant" element={<AdminOnlyRoute><InvoiceMaker /></AdminOnlyRoute>} />
        <Route path="settings/users" element={<AdminOnlyRoute><Users /></AdminOnlyRoute>} />
        <Route path="settings/organizations" element={<SuperAdminOnlyRoute><Organizations /></SuperAdminOnlyRoute>} />
        <Route path="settings/tax-config" element={<AdminOnlyRoute><TaxConfigs /></AdminOnlyRoute>} />
        <Route path="settings/audit-logs" element={<AdminOnlyRoute><AuditLogs /></AdminOnlyRoute>} />
        <Route path="settings/client-documents" element={<StaffOnlyRoute><AdminClientDocumentsPage /></StaffOnlyRoute>} />
        <Route path="settings/client-change-requests" element={<ManagerOnlyRoute><AdminEmployeeChangeRequestsPage /></ManagerOnlyRoute>} />
        <Route path="check-settings" element={<ManagerOnlyRoute><CheckSettingsPage /></ManagerOnlyRoute>} />
        <Route path="payroll-reminders" element={<ManagerOnlyRoute><PayrollReminders /></ManagerOnlyRoute>} />
        <Route path="time-tracking-sources" element={<AdminOnlyRoute><TimeTrackingSources /></AdminOnlyRoute>} />
        <Route path="pay-schedule-settings" element={<ManagerOnlyRoute><PayScheduleSettings /></ManagerOnlyRoute>} />
        <Route path="settings/clients" element={<StaffOnlyRoute><Clients /></StaffOnlyRoute>} />
      </Route>

      {/* Catch-all redirect */}
      <Route path="*" element={<Navigate to="/app" replace />} />
        </Routes>
      </Suspense>
    </RouteErrorBoundary>
  );
}

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;

function AppWithClerk({ children }: { children: React.ReactNode }) {
  if (!clerkPubKey) {
    // Dev mode — no Clerk, AuthProvider handles fallback
    return <>{children}</>;
  }
  return (
    <ClerkProvider publishableKey={clerkPubKey}>
      {children}
    </ClerkProvider>
  );
}

function App() {
  return (
    <BrowserRouter>
      <PostHogPageView />
      <AppWithClerk>
        <AuthProvider>
          <PostHogIdentify />
          <CompanyProvider>
            <AppRoutes />
          </CompanyProvider>
        </AuthProvider>
      </AppWithClerk>
    </BrowserRouter>
  );
}

export default App;
