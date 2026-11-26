// Staff surface entry. Vite resolves the employee surface to EmployeeApp.tsx.
import { Component, lazy, Suspense, useEffect, useRef, type ErrorInfo, type ReactElement, type ReactNode } from 'react';
import { createBrowserRouter, RouterProvider, Routes, Route, Navigate, useLocation } from 'react-router';
import { ClerkProvider } from '@clerk/react';
// Pinned so a Clerk CDN update can't change the sign-in markup our styles target.
import { ui as clerkUi } from '@clerk/ui';
import { useSelectedCompanyCapability, type ClientCapability } from '@/hooks/useSelectedCompanyCapability';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { CompanyProvider, useCompany } from '@/contexts/CompanyContext';
import { FinanceBookGate } from '@/contexts/FinanceBookContext';
import { PostHogPageView, usePostHog, isPostHogEnabled } from '@/providers/PostHogProvider';
import { registerAnalyticsContext, resetAnalytics } from '@/lib/analytics';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { Layout } from '@/components/layout/Layout';
import { CompanyScopedRoute } from '@/components/routing/CompanyScopedRoute';
import { isPublicPath } from '@/lib/public-routes';
import { clearStoredAuthReturnPath, loginRedirectPath, readStoredAuthReturnPath } from '@/lib/auth-return-url';
import { LegacyCompanyRedirect } from '@/components/routing/LegacyCompanyRedirect';
import { AccountAccessNotice } from '@/components/auth/AccountAccessNotice';
import { EmployeeAppAccessNotice } from '@/components/auth/EmployeeAppAccessNotice';
import { isMfaRequiredCode } from '@/services/api';

const ClientOperatingProfile = lazy(() => import('@/pages/ClientOperatingProfile').then(module => ({ default: module.ClientOperatingProfile })));
const EmployeeAppRollout = lazy(() => import('@/pages/EmployeeAppRollout').then(module => ({ default: module.EmployeeAppRollout })));
const EmployeeAppSettings = lazy(() => import('@/pages/EmployeeAppSettings').then(module => ({ default: module.EmployeeAppSettings })));
const EmployeeAppSwitch = lazy(() => import('@/pages/EmployeeAppSwitch').then(module => ({ default: module.EmployeeAppSwitch })));
const ClientInbox = lazy(() => import('@/pages/ClientInbox').then(module => ({ default: module.ClientInbox })));
const ClientMessages = lazy(() => import('@/pages/client/ClientMessages').then(module => ({ default: module.ClientMessages })));
const PayrollPeriodsList = lazy(() => import('@/pages/payroll-submissions/PayrollPeriodsList').then(module => ({ default: module.PayrollPeriodsList })));
const PayrollPeriodPage = lazy(() => import('@/pages/payroll-submissions/PayrollPeriodPage').then(module => ({ default: module.PayrollPeriodPage })));
const Dashboard = lazy(() => import('@/pages/Dashboard').then((module) => ({ default: module.Dashboard })));
const EmployeeList = lazy(() => import('@/pages/employees/EmployeeList').then((module) => ({ default: module.EmployeeList })));
const EmployeeContactDetails = lazy(() => import('@/pages/employees/EmployeeContactDetails').then((module) => ({ default: module.EmployeeContactDetails })));
const StaffEmployeeContactDetails = lazy(() => import('@/pages/employees/StaffEmployeeContactDetails').then((module) => ({ default: module.StaffEmployeeContactDetails })));
const EmployeeForm = lazy(() => import('@/pages/employees/EmployeeForm').then((module) => ({ default: module.EmployeeForm })));
const EmployeeWorkspace = lazy(() => import('@/pages/employees/EmployeeWorkspace').then((module) => ({ default: module.EmployeeWorkspace })));
const ClientEmployeeOverview = lazy(() => import('@/pages/employees/ClientEmployeeOverview').then((module) => ({ default: module.ClientEmployeeOverview })));
const Departments = lazy(() => import('@/pages/Departments').then((module) => ({ default: module.Departments })));
const PayPeriods = lazy(() => import('@/pages/PayPeriods').then((module) => ({ default: module.PayPeriods })));
const PayRunWorkspace = lazy(() => import('@/pages/pay-periods/PayRunWorkspace').then((module) => ({ default: module.PayRunWorkspace })));
const ImportedPayRunDetail = lazy(() => import('@/pages/pay-periods/ImportedPayRunDetail').then((module) => ({ default: module.ImportedPayRunDetail })));
const PayrollItemDetail = lazy(() => import('@/pages/payroll-items/PayrollItemDetail').then((module) => ({ default: module.PayrollItemDetail })));
const Reports = lazy(() => import('@/pages/Reports').then((module) => ({ default: module.Reports })));
const ClientProfitability = lazy(() => import('@/pages/ClientProfitability').then((module) => ({ default: module.ClientProfitability })));
const ChecksPayments = lazy(() => import('@/pages/ChecksPayments').then((module) => ({ default: module.ChecksPayments })));
import { ClientGrant, ClientSupportView } from '@/support/ClientSupportView';
import { StartSupportView } from '@/support/StartSupportView';
import { SupportAccessLogs } from '@/support/SupportAccessLogs';
import { supportToken } from '@/support/grant';

const ClientDashboard = lazy(() => import('@/pages/client/ClientDashboard').then((module) => ({ default: module.ClientDashboard })));
const ClientPayPeriods = lazy(() => import('@/pages/client/ClientPayPeriods').then((module) => ({ default: module.ClientPayPeriods })));
const ClientPayPeriodDetail = lazy(() => import('@/pages/client/ClientPayPeriodDetail').then((module) => ({ default: module.ClientPayPeriodDetail })));
const ClientReports = lazy(() => import('@/pages/client/ClientReports').then((module) => ({ default: module.ClientReports })));
const ClientDocuments = lazy(() => import('@/pages/client/ClientDocuments').then((module) => ({ default: module.ClientDocuments })));
const EmployeeContactChangesToConfirm = lazy(() => import('@/pages/EmployeeContactChangesToConfirm').then((module) => ({ default: module.EmployeeContactChangesToConfirm })));
const ClientChangeRequests = lazy(() => import('@/pages/client/ClientChangeRequests').then((module) => ({ default: module.ClientChangeRequests })));
const Form500Page = lazy(() => import('@/pages/Form500Page').then((module) => ({ default: module.Form500Page })));
const AdminClientDocumentsPage = lazy(() => import('@/pages/AdminClientDocumentsPage').then((module) => ({ default: module.AdminClientDocumentsPage })));
const AdminClientMessagesPage = lazy(() => import('@/pages/AdminClientMessagesPage').then((module) => ({ default: module.AdminClientMessagesPage })));
const AdminEmployeeChangeRequestsPage = lazy(() => import('@/pages/AdminEmployeeChangeRequestsPage').then((module) => ({ default: module.AdminEmployeeChangeRequestsPage })));
const TaxConfigs = lazy(() => import('@/pages/TaxConfigs'));
const Users = lazy(() => import('@/pages/Users').then((module) => ({ default: module.Users })));
const Organizations = lazy(() => import('@/pages/Organizations').then((module) => ({ default: module.Organizations })));
const AuditLogs = lazy(() => import('@/pages/AuditLogs').then((module) => ({ default: module.AuditLogs })));
const CheckSettingsPage = lazy(() => import('@/pages/CheckSettings').then((module) => ({ default: module.CheckSettingsPage })));
const EmployeeLoans = lazy(() => import('@/pages/EmployeeLoans'));
const PayrollFields = lazy(() => import('@/pages/PayrollFields'));
const Clients = lazy(() => import('@/pages/Clients').then((module) => ({ default: module.Clients })));
const YearEnd = lazy(() => import('@/pages/YearEnd').then((module) => ({ default: module.YearEnd })));
const YearEndChecklist = lazy(() => import('@/pages/YearEndChecklist').then((module) => ({ default: module.YearEndChecklist })));
const TimecardOcrTool = lazy(() => import('@/pages/TimecardOcrTool').then((module) => ({ default: module.TimecardOcrTool })));
const GeneralTransmittals = lazy(() => import('@/pages/GeneralTransmittals').then((module) => ({ default: module.GeneralTransmittals })));
const InvoiceMaker = lazy(() => import('@/pages/InvoiceMaker').then((module) => ({ default: module.InvoiceMaker })));
const InvoiceCenter = lazy(() => import('@/pages/InvoiceCenter').then((module) => ({ default: module.InvoiceCenter })));
const InvoiceStyleSettings = lazy(() => import('@/pages/InvoiceStyleSettings').then((module) => ({ default: module.InvoiceStyleSettings })));
const ExpenseLedger = lazy(() => import('@/pages/ExpenseLedger').then((module) => ({ default: module.ExpenseLedger })));
const FinanceOverview = lazy(() => import('@/pages/FinanceOverview').then((module) => ({ default: module.FinanceOverview })));
const FinanceAgentAccess = lazy(() => import('@/pages/FinanceAgentAccess').then((module) => ({ default: module.FinanceAgentAccess })));
const StandingChangesSettings = lazy(() => import('@/pages/StandingChangesSettings'));
const PayrollReminders = lazy(() => import('@/pages/PayrollReminders'));
const TimeTrackingSources = lazy(() => import('@/pages/TimeTrackingSources').then((module) => ({ default: module.TimeTrackingSources })));
const AireHistoryApproval = lazy(() => import('@/pages/AireHistoryApproval').then((module) => ({ default: module.AireHistoryApproval })));
const AireAccountConnection = lazy(() => import('@/pages/AireAccountConnection').then((module) => ({ default: module.AireAccountConnection })));
const NotificationSettings = lazy(() => import('@/pages/NotificationSettings').then((module) => ({ default: module.NotificationSettings })));
const AccountSecurity = lazy(() => import('@/pages/AccountSecurity').then((module) => ({ default: module.AccountSecurity })));
const PayScheduleSettings = lazy(() => import('@/pages/PayScheduleSettings').then((module) => ({ default: module.PayScheduleSettings })));
const PriorProviderHistory = lazy(() => import('@/pages/PriorProviderHistory').then(module => ({ default: module.PriorProviderHistory })));
const HistoricalPayroll = lazy(() => import('@/pages/HistoricalPayroll').then((module) => ({ default: module.HistoricalPayroll })));
const PayrollGoLive = lazy(() => import('@/pages/PayrollGoLive').then((module) => ({ default: module.PayrollGoLive })));
const Login = lazy(() => import('@/pages/Login').then((module) => ({ default: module.Login })));
const Invite = lazy(() => import('@/pages/Invite').then((module) => ({ default: module.Invite })));
const PublicHome = lazy(() => import('@/pages/PublicHome').then((module) => ({ default: module.PublicHome })));
const PrivacyPolicy = lazy(() => import('@/pages/legal/PrivacyPolicy').then((module) => ({ default: module.PrivacyPolicy })));
const TermsOfService = lazy(() => import('@/pages/legal/TermsOfService').then((module) => ({ default: module.TermsOfService })));

// Environment flag to bypass auth in development
const AUTH_ENABLED = import.meta.env.VITE_AUTH_ENABLED === 'true';

// Protected route wrapper
function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading, user, authProblem } = useAuth();
  const location = useLocation();
  const mfaBlocked = authProblem?.status === 403 && isMfaRequiredCode(authProblem.code);

  useEffect(() => {
    if (isAuthenticated && !mfaBlocked) {
      clearStoredAuthReturnPath();
    }
  }, [isAuthenticated, mfaBlocked]);

  if (mfaBlocked) {
    return <Navigate to={loginRedirectPath(location)} replace />;
  }

  // Skip auth check if disabled. A refused account still gets an explanation
  // instead of an empty staff-style workspace.
  if (!AUTH_ENABLED) {
    if (!isLoading && !user && authProblem) {
      return (
        <div className="flex min-h-screen items-center justify-center bg-gray-50 px-4 py-12">
          <AccountAccessNotice className="w-full max-w-lg" problem={authProblem} onRetry={() => window.location.reload()} />
        </div>
      );
    }
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
    return <Navigate to={loginRedirectPath(location)} replace />;
  }

  return <>{children}</>;
}

function CallbackRedirect(): ReactElement {
  const destination = readStoredAuthReturnPath() ?? '/app';
  return <Navigate to={destination} replace />;
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

function AuditHistoryRoute({ children }: { children: React.ReactNode }): ReactElement {
  const { isAdmin, isAccountant, isLoading } = useAuth();

  if (isLoading) {
    return <PageLoader />;
  }

  if (!isAdmin && !isAccountant) {
    return <Navigate to="/app" replace />;
  }

  return <>{children}</>;
}

function CapabilityRoute({ children, capability, clientCapability }: { children: React.ReactNode; capability: string; clientCapability?: ClientCapability }) {
  const { hasCapability, isLoading } = useAuth();

  const hasClientCapability = useSelectedCompanyCapability(clientCapability ?? 'manage_client_configuration');
  const { loading: companyLoading } = useCompany();
  if (isLoading || (clientCapability && companyLoading)) return <PageLoader />;
  if (!(clientCapability ? hasClientCapability : hasCapability(capability))) return <Navigate to="/app" replace />;

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

interface HistoricalPayrollRouteProps {
  children: React.ReactNode;
}

function HistoricalPayrollRoute({ children }: HistoricalPayrollRouteProps): ReactElement {
  const { activeCompany, loading } = useCompany();

  if (loading) return <PageLoader />;
  if (!activeCompany?.historical_payroll_enabled) return <Navigate to="/app" replace />;

  return <StaffOnlyRoute>{children}</StaffOnlyRoute>;
}

function PayrollFilesRoute({ children }: { children: React.ReactNode }) {
  return <ClientOnlyRoute>{children}</ClientOnlyRoute>;
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

export function PostHogSessionSync(): null {
  const { user } = useAuth();
  const posthog = usePostHog();
  const lastUserId = useRef<number | null>(null);

  useEffect(() => {
    if (!isPostHogEnabled || !posthog) return;
    if (user) {
      if (lastUserId.current !== null && lastUserId.current !== user.id) {
        resetAnalytics(posthog, { surface: 'staff', keepRole: false });
      }
      registerAnalyticsContext(posthog, {
        role: user.role,
        surface: 'staff',
      });
      lastUserId.current = user.id;
    } else if (lastUserId.current !== null) {
      resetAnalytics(posthog, { surface: 'staff', keepRole: false });
      lastUserId.current = null;
    }
  }, [user, posthog]);

  return null;
}

function PageLoader(): ReactElement {
  return (
    <div className="flex min-h-[320px] items-center justify-center px-6 py-12">
      <div className="inline-flex items-center gap-3 rounded-full border border-neutral-200 bg-white/85 px-4 py-2 text-sm font-medium text-neutral-600 shadow-sm shadow-neutral-200/70">
        <span className="h-4 w-4 animate-spin rounded-full border-2 border-primary-200 border-t-primary-600" aria-hidden="true" />
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
      <Route path="/privacy" element={<PrivacyPolicy />} />
      <Route path="/terms" element={<TermsOfService />} />
      <Route path="/callback" element={<CallbackRedirect />} />

      {/* Protected routes */}
      <Route
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route path="/app" element={isClient ? <ClientDashboard /> : <Dashboard />} />
        <Route path="/app/client-inbox" element={<StaffOnlyRoute><ClientInbox /></StaffOnlyRoute>} />
        <Route path="/app/sign-in-as" element={<CapabilityRoute capability="start_view_as"><StartSupportView /></CapabilityRoute>} />
        <Route path="/support-access" element={<ClientOnlyRoute><SupportAccessLogs /></ClientOnlyRoute>} />
        <Route path="/messages" element={<ClientOnlyRoute><ClientMessages /></ClientOnlyRoute>} />
        <Route path="/payroll-files" element={<PayrollFilesRoute><PayrollPeriodsList audience="client" /></PayrollFilesRoute>} />
        <Route path="/payroll-files/:ref" element={<PayrollFilesRoute><PayrollPeriodPage audience="client" /></PayrollFilesRoute>} />
        <Route path="/app/notifications" element={<NotificationSettings />} />
        <Route path="/app/account-security" element={<AccountSecurity />} />
        <Route path="/app/aire-account-connection" element={<CapabilityRoute capability="manage_own_aire_account_link"><AireAccountConnection /></CapabilityRoute>} />
        <Route path="/app/time-account-connection" element={<CapabilityRoute capability="manage_own_aire_account_link"><AireAccountConnection /></CapabilityRoute>} />
        <Route path="/app/aire-history-approval" element={<CapabilityRoute capability="payroll_operations"><AireHistoryApproval /></CapabilityRoute>} />
        <Route path="employees" element={<LegacyCompanyRedirect destination="employees" />} />
        <Route path="employees/contact-details" element={<LegacyCompanyRedirect destination="contact-details" />} />
        <Route path="contact-details" element={<LegacyCompanyRedirect destination="contact-details" />} />
        <Route path="employees/new" element={<LegacyCompanyRedirect destination="new-employee" />} />
        <Route path="employees/:id" element={<LegacyCompanyRedirect destination="employee" clientMode={isClient} />} />
        <Route path="departments" element={<Departments />} />
        <Route path="pay-periods" element={<LegacyCompanyRedirect destination="pay-runs" />} />
        <Route path="pay-periods/:id" element={<LegacyCompanyRedirect destination="pay-run" clientMode={isClient} />} />
        <Route path="companies/:companyId" element={<CompanyScopedRoute />}>
          <Route path="operating-profile" element={<StaffOnlyRoute><ClientOperatingProfile /></StaffOnlyRoute>} />
          <Route path="employee-app" element={<EmployeeAppSettings />} />
          <Route path="employee-app/rollout" element={<EmployeeAppRollout audience={isClient ? 'client' : 'admin'} />} />
          <Route path="employee-app/switch" element={<StaffOnlyRoute><CapabilityRoute capability="manage_employee_app_switch"><EmployeeAppSwitch /></CapabilityRoute></StaffOnlyRoute>} />
          <Route path="messages" element={<ClientOnlyRoute><ClientMessages /></ClientOnlyRoute>} />
          <Route path="documents" element={<ClientOnlyRoute><ClientDocuments /></ClientOnlyRoute>} />
          <Route path="change-requests" element={<ClientOnlyRoute><ClientChangeRequests /></ClientOnlyRoute>} />
          <Route path="payroll-files" element={<PayrollFilesRoute><PayrollPeriodsList audience="client" /></PayrollFilesRoute>} />
          <Route path="client-documents" element={<StaffOnlyRoute><AdminClientDocumentsPage /></StaffOnlyRoute>} />
          <Route path="client-messages" element={<StaffOnlyRoute><AdminClientMessagesPage /></StaffOnlyRoute>} />
          <Route path="payroll-submissions" element={<StaffOnlyRoute><PayrollPeriodsList audience="staff" /></StaffOnlyRoute>} />
          <Route path="payroll-submissions/:ref" element={<StaffOnlyRoute><PayrollPeriodPage audience="staff" /></StaffOnlyRoute>} />
          <Route path="contact-changes-to-confirm" element={<StaffOnlyRoute><CapabilityRoute capability="payroll_operations"><EmployeeContactChangesToConfirm /></CapabilityRoute></StaffOnlyRoute>} />
          <Route path="client-change-requests" element={<CapabilityRoute capability="manage_client_configuration" clientCapability="manage_client_configuration"><AdminEmployeeChangeRequestsPage /></CapabilityRoute>} />
          <Route path="employees" element={<EmployeeList />} />
          <Route path="employees/contact-details" element={isClient ? <EmployeeContactDetails /> : <StaffEmployeeContactDetails />} />
          <Route path="employees/new" element={<EmployeeForm />} />
          <Route path="employees/:id/edit" element={<EmployeeForm />} />
          <Route path="employees/:id/:tab?" element={isClient ? <ClientEmployeeOverview /> : <EmployeeWorkspace />} />
          <Route path="pay-runs" element={isClient ? <ClientPayPeriods /> : <PayPeriods />} />
          <Route path="pay-runs/imported/:id" element={<ImportedPayRunDetail audience={isClient ? 'client' : 'staff'} />} />
          <Route path="pay-runs/:id/payroll-items/:payrollItemId" element={<StaffOnlyRoute><PayrollItemDetail /></StaffOnlyRoute>} />
          <Route path="pay-runs/:id/:tab?" element={isClient ? <ClientPayPeriodDetail /> : <PayRunWorkspace />} />
          <Route path="prior-provider-history" element={<StaffOnlyRoute><PriorProviderHistory /></StaffOnlyRoute>} />
          <Route path="payroll-go-live" element={<StaffOnlyRoute><PayrollGoLive /></StaffOnlyRoute>} />
          <Route path="payroll-fields" element={<CapabilityRoute capability="manage_payroll_fields"><PayrollFields /></CapabilityRoute>} />
          <Route path="year-end" element={<StaffOnlyRoute><YearEndChecklist /></StaffOnlyRoute>} />
        </Route>
        <Route path="historical-payroll" element={<HistoricalPayrollRoute><HistoricalPayroll /></HistoricalPayrollRoute>} />
        <Route path="checks-payments" element={<StaffOnlyRoute><ChecksPayments /></StaffOnlyRoute>} />
        <Route path="pay-periods/:id/form-500" element={<StaffOnlyRoute><Form500Page /></StaffOnlyRoute>} />
        <Route path="payroll/run" element={<Navigate to="/pay-periods" replace />} />
        <Route path="reports" element={isClient ? <ClientReports /> : <Reports />} />
        <Route path="reports/client-profitability" element={<CapabilityRoute capability="view_client_profitability"><ClientProfitability /></CapabilityRoute>} />
        <Route path="year-end" element={<StaffOnlyRoute><YearEnd /></StaffOnlyRoute>} />
        <Route path="documents" element={<ClientOnlyRoute><ClientDocuments /></ClientOnlyRoute>} />
        <Route path="change-requests" element={<ClientOnlyRoute><ClientChangeRequests /></ClientOnlyRoute>} />
        <Route path="employee-loans" element={<StaffOnlyRoute><EmployeeLoans /></StaffOnlyRoute>} />
        <Route path="payroll-fields" element={<CapabilityRoute capability="manage_payroll_fields"><PayrollFields /></CapabilityRoute>} />
        <Route path="tools/timecard-ocr" element={<StaffOnlyRoute><TimecardOcrTool /></StaffOnlyRoute>} />
        <Route path="tools/transmittals" element={<StaffOnlyRoute><GeneralTransmittals /></StaffOnlyRoute>} />
        <Route path="tools/invoices" element={<AdminOnlyRoute><FinanceBookGate><InvoiceCenter /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="tools/finance" element={<AdminOnlyRoute><FinanceBookGate><FinanceOverview /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="tools/finance/agent-access" element={<AdminOnlyRoute><FinanceBookGate><FinanceAgentAccess /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="tools/expenses" element={<AdminOnlyRoute><FinanceBookGate><ExpenseLedger /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="tools/invoices/assistant" element={<AdminOnlyRoute><FinanceBookGate><InvoiceMaker /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="tools/invoices/billing-profiles/:profileId/style" element={<AdminOnlyRoute><FinanceBookGate><InvoiceStyleSettings /></FinanceBookGate></AdminOnlyRoute>} />
        <Route path="settings/users" element={<AdminOnlyRoute><Users /></AdminOnlyRoute>} />
        <Route path="settings/organizations" element={<SuperAdminOnlyRoute><Organizations /></SuperAdminOnlyRoute>} />
        <Route path="settings/tax-config" element={<AdminOnlyRoute><TaxConfigs /></AdminOnlyRoute>} />
        <Route path="settings/audit-logs" element={<AuditHistoryRoute><AuditLogs /></AuditHistoryRoute>} />
        <Route path="settings/client-documents" element={<StaffOnlyRoute><AdminClientDocumentsPage /></StaffOnlyRoute>} />
        <Route path="settings/client-messages" element={<StaffOnlyRoute><AdminClientMessagesPage /></StaffOnlyRoute>} />
        <Route path="settings/payroll-submissions" element={<StaffOnlyRoute><PayrollPeriodsList audience="staff" /></StaffOnlyRoute>} />
        <Route path="settings/payroll-submissions/:ref" element={<StaffOnlyRoute><PayrollPeriodPage audience="staff" /></StaffOnlyRoute>} />
        <Route path="settings/client-change-requests" element={<CapabilityRoute capability="manage_client_configuration" clientCapability="manage_client_configuration"><AdminEmployeeChangeRequestsPage /></CapabilityRoute>} />
        <Route path="check-settings" element={<CapabilityRoute capability="use_printer_profiles"><CheckSettingsPage /></CapabilityRoute>} />
        <Route path="payroll-reminders" element={<CapabilityRoute capability="manage_client_configuration" clientCapability="manage_client_configuration"><PayrollReminders /></CapabilityRoute>} />
        <Route path="time-tracking-sources" element={<AdminOnlyRoute><TimeTrackingSources /></AdminOnlyRoute>} />
        <Route path="standing-changes" element={<CapabilityRoute capability="manage_client_configuration" clientCapability="manage_client_configuration"><StandingChangesSettings /></CapabilityRoute>} />
        <Route path="pay-schedule-settings" element={<CapabilityRoute capability="manage_client_configuration" clientCapability="manage_client_configuration"><PayScheduleSettings /></CapabilityRoute>} />
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
    <ClerkProvider publishableKey={clerkPubKey} ui={clerkUi}>
      {children}
    </ClerkProvider>
  );
}

function AppFeedback({ children }: { children: ReactNode }) {
  const { user, isLoading: authLoading } = useAuth();
  const { activeCompanyId, activeOrganizationId, loading: companyLoading } = useCompany();
  const { pathname } = useLocation();
  if (!isPublicPath(pathname) && (authLoading || companyLoading)) return <PageLoader />;
  const financePage = pathname.startsWith('/tools/invoices') || pathname.startsWith('/tools/expenses') || pathname.startsWith('/tools/finance');
  const scope = `${user?.id ?? 'signed-out'}:${activeOrganizationId ?? 'none'}:${financePage ? 'finance' : activeCompanyId ?? 'none'}`;
  return <FeedbackProvider key={scope} scopeKey={scope}>{children}</FeedbackProvider>;
}

const developmentToken = async () => null;

function StaffWorkspace(): ReactElement {
  const { user, isAuthenticated } = useAuth();
  const { pathname } = useLocation();
  const content = <AppFeedback><AppRoutes /></AppFeedback>;
  if (isAuthenticated && user?.role === 'portal_employee') {
    return isPublicPath(pathname) ? content : <EmployeeAppAccessNotice />;
  }

  return <CompanyProvider>{content}</CompanyProvider>;
}

function AppContents() {
  const workspace = (
    <AuthProvider>
      {!supportToken && <PostHogSessionSync />}
      <StaffWorkspace />
    </AuthProvider>
  );
  return (
    <>
      {!supportToken && <PostHogPageView surface="staff" />}
      <AppWithClerk>
        {supportToken
          ? clerkPubKey
            ? <ClientSupportView>{workspace}</ClientSupportView>
            : import.meta.env.DEV ? <ClientGrant getToken={developmentToken}>{workspace}</ClientGrant> : <p>Staff sign-in is unavailable.</p>
          : workspace}
      </AppWithClerk>
    </>
  );
}

const router = createBrowserRouter([{ path: '*', element: <AppContents /> }]);

function App() {
  return <RouterProvider router={router} />;
}

export default App;
