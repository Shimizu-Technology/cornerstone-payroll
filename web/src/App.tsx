import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { ClerkProvider } from '@clerk/clerk-react';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { Layout } from '@/components/layout/Layout';
import { Dashboard } from '@/pages/Dashboard';
import { EmployeeList } from '@/pages/employees/EmployeeList';
import { EmployeeForm } from '@/pages/employees/EmployeeForm';
import { Departments } from '@/pages/Departments';
import { PayPeriods } from '@/pages/PayPeriods';
import { PayPeriodDetail } from '@/pages/PayPeriodDetail';
// PayrollRun removed — workflow lives in PayPeriodDetail
import { Reports } from '@/pages/Reports';
import TaxConfigs from '@/pages/TaxConfigs';
import { Users } from '@/pages/Users';
import { AuditLogs } from '@/pages/AuditLogs';
import { Login } from '@/pages/Login';
// AuthCallback removed — Clerk handles auth flow
import { Invite } from '@/pages/Invite';

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

function AppRoutes() {
  return (
    <Routes>
      {/* Public routes */}
      <Route path="/login" element={<Login />} />
      <Route path="/invite" element={<Invite />} />
      <Route path="/callback" element={<Navigate to="/" replace />} />

      {/* Protected routes */}
      <Route
        path="/"
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route index element={<Dashboard />} />
        <Route path="employees" element={<EmployeeList />} />
        <Route path="employees/new" element={<EmployeeForm />} />
        <Route path="employees/:id" element={<EmployeeForm />} />
        <Route path="departments" element={<Departments />} />
        <Route path="pay-periods" element={<PayPeriods />} />
        <Route path="pay-periods/:id" element={<PayPeriodDetail />} />
        <Route path="payroll/run" element={<Navigate to="/pay-periods" replace />} />
        <Route path="reports" element={<Reports />} />
        <Route path="settings/users" element={<Users />} />
        <Route path="settings/tax-config" element={<TaxConfigs />} />
        <Route path="settings/audit-logs" element={<AuditLogs />} />
      </Route>

      {/* Catch-all redirect */}
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
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
      <AppWithClerk>
        <AuthProvider>
          <AppRoutes />
        </AuthProvider>
      </AppWithClerk>
    </BrowserRouter>
  );
}

export default App;
