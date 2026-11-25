/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react';
import { useAuth as useClerkAuth } from '@clerk/react';
import { ApiError, authApi, isMfaRequiredCode, MFA_REQUIRED_EVENT, setAuthToken, setAuthTokenProvider } from '@/services/api';
import { clearAllDrafts } from '@/components/client-portal/messageDrafts';
import { resetAnalytics } from '@/lib/analytics';

interface User {
  id: number;
  email: string;
  name: string;
  role: string;
  organization_id?: number;
  organization_name?: string;
  company_id: number | null;
  company_name: string | null;
  assigned_company_ids: number[];
  capabilities: string[];
  company_capabilities?: Record<string, string[]>;
}

/** Why the backend refused to open an account, kept so the sign-in screen can explain it. */
export interface AuthProblem {
  status: number | null;
  code?: string;
  message: string;
  signOutFailed?: boolean;
}

interface AuthContextType {
  user: User | null;
  authProblem: AuthProblem | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  isAdmin: boolean;
  isSuperAdmin: boolean;
  isManager: boolean;
  isAccountant: boolean;
  isClient: boolean;
  hasCapability: (capability: string) => boolean;
  signOut: (options?: { redirectUrl: string }) => Promise<void>;
  refreshUser: (options?: { skipTokenCache?: boolean }) => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

function authProblemFrom(err: unknown): AuthProblem {
  if (err instanceof ApiError) {
    const { data } = err;
    const code = data && typeof data === 'object' && 'code' in data && typeof data.code === 'string' ? data.code : undefined;
    return { status: err.status, code, message: err.message };
  }
  return { status: null, message: err instanceof Error ? err.message : 'Could not load your account' };
}
const mfaRequiredProblem: AuthProblem = {
  status: 403,
  code: 'mfa_required',
  message: 'Multi-factor authentication is required before accessing payroll.',
};

type AuthResponseUser = NonNullable<Awaited<ReturnType<typeof authApi.me>>['user']>;

function mapAuthUser(user: AuthResponseUser): User {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    role: user.role,
    organization_id: user.organization_id,
    organization_name: user.organization_name,
    company_id: user.company_id,
    company_name: user.company_name,
    assigned_company_ids: user.assigned_company_ids || [],
    capabilities: user.capabilities || [],
    company_capabilities: user.company_capabilities || {},
  };
}

// Dev mode bypass — when VITE_CLERK_PUBLISHABLE_KEY is not set
const isDevMode = !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;
const authEnabled = import.meta.env.VITE_AUTH_ENABLED === 'true';

function isAdminRole(role?: string) {
  return role === 'admin' || role === 'org_admin' || role === 'super_admin';
}

function DevAuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [authProblem, setAuthProblem] = useState<AuthProblem | null>(null);
  const [isLoading, setIsLoading] = useState(!authEnabled);

  useEffect(() => {
    // Dev mode does not rely on Clerk token provider.
    setAuthTokenProvider(null);
    setAuthToken(null);
  }, []);

  useEffect(() => {
    // If auth is enabled but Clerk is not configured, don't hammer /auth/me.
    // The UI should route to /login and show the missing configuration state.
    if (authEnabled) {
      return;
    }

    // In dev mode, just fetch /auth/me without a token
    authApi.me()
      .then((res) => {
        if (!res.user) throw new Error('Could not load your account');
        setUser(mapAuthUser(res.user));
        setAuthProblem(null);
      })
      .catch((err) => { setUser(null); setAuthProblem(authProblemFrom(err)); })
      .finally(() => setIsLoading(false));
  }, []);

  return (
    <AuthContext.Provider
      value={{
        user,
        authProblem,
        isLoading,
        isAuthenticated: !!user,
        isAdmin: isAdminRole(user?.role),
        isSuperAdmin: user?.role === 'super_admin',
        isManager: user?.role === 'manager' || isAdminRole(user?.role),
        isAccountant: user?.role === 'accountant',
        isClient: user?.role === 'client',
        hasCapability: (capability) => user?.capabilities.includes(capability) === true,
        signOut: async () => {
          setUser(null);
          clearAllDrafts();
          authApi.logout();
        },
        refreshUser: async () => {
          const res = await authApi.me();
          if (!res.user) throw new Error('Could not load your account');
          setUser(mapAuthUser(res.user));
          setAuthProblem(null);
        },
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
  const { isSignedIn, isLoaded, getToken, signOut: clerkSignOut } = useClerkAuth();
  const [user, setUser] = useState<User | null>(null);
  const [authProblem, setAuthProblem] = useState<AuthProblem | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const backendUnauthorized = useRef(false);

  useEffect(() => {
    if (!isSignedIn) {
      setAuthTokenProvider(null);
      setAuthToken(null);
      return;
    }

    // Always fetch a fresh Clerk token before API requests.
    setAuthTokenProvider(() => getToken());
  }, [isSignedIn, getToken]);

  useEffect(() => {
    if (!isSignedIn) return;

    const requireMfa = (event: Event) => {
      const detail = (event as CustomEvent<{ code?: unknown; message?: unknown } | string | undefined>).detail;
      const code = typeof detail === 'object' && detail && isMfaRequiredCode(detail.code)
        ? detail.code
        : 'mfa_required';
      const message = typeof detail === 'object' && detail && typeof detail.message === 'string'
        ? detail.message
        : typeof detail === 'string'
          ? detail
          : mfaRequiredProblem.message;
      setUser(null);
      setAuthProblem({ status: 403, code, message });
    };
    window.addEventListener(MFA_REQUIRED_EVENT, requireMfa);
    return () => window.removeEventListener(MFA_REQUIRED_EVENT, requireMfa);
  }, [isSignedIn]);

  const refreshUser = useCallback(async (options?: { skipTokenCache?: boolean }) => {
    if (!isSignedIn) {
      setUser(null);
      setAuthProblem((problem) => isMfaRequiredCode(problem?.code) ? null : problem);
      backendUnauthorized.current = false;
      setIsLoading(false);
      return;
    }

    if (backendUnauthorized.current) {
      setIsLoading(false);
      return;
    }

    try {
      const token = options?.skipTokenCache ? await getToken({ skipCache: true }) : await getToken();
      if (token) {
        // Set token for API calls
        setAuthToken(token);
      }

      const res = options?.skipTokenCache ? await authApi.me(token) : await authApi.me();
      if (res.mfa_required === true && res.mfa_verified === false) {
        // The bootstrap carries the same code as every MFA 403: set up a
        // second factor (mfa_enrollment_required) or finish it (mfa_required).
        setUser(null);
        setAuthProblem(isMfaRequiredCode(res.code)
          ? { status: 403, code: res.code, message: typeof res.error === 'string' && res.error ? res.error : mfaRequiredProblem.message }
          : mfaRequiredProblem);
        return;
      }

      if (!res.user) throw new Error('Could not load your account');
      setUser(mapAuthUser(res.user));
      setAuthProblem(null);
    } catch (err) {
      const problem = authProblemFrom(err);
      setUser(null);
      if (err instanceof ApiError && err.status === 401) {
        // Suppress duplicate sign-outs while Clerk clears the rejected session.
        if (!backendUnauthorized.current) {
          backendUnauthorized.current = true;
          setAuthProblem(problem);
          setAuthToken(null);
          try {
            await clerkSignOut();
          } catch {
            backendUnauthorized.current = false;
            setAuthProblem({ ...problem, signOutFailed: true });
          }
        }
      } else {
        setAuthProblem(problem);
        if (problem.status !== 403 || !isMfaRequiredCode(problem.code)) {
          console.error('Failed to load user:', err);
        }
      }
    } finally {
      setIsLoading(false);
    }
  }, [isSignedIn, getToken, clerkSignOut]);

  // Refresh user when Clerk auth state changes
  useEffect(() => {
    if (isLoaded) {
      refreshUser();
    }
  }, [isLoaded, isSignedIn, refreshUser]);

  // Keep token fresh
  useEffect(() => {
    if (!isSignedIn) return;

    const interval = setInterval(async () => {
      try {
        const token = await getToken();
        if (token) {
          setAuthToken(token);
        }
      } catch {
        // Clerk Core 3 throws while offline; the next tick or request retries.
      }
    }, 50000); // Refresh every 50s

    return () => clearInterval(interval);
  }, [isSignedIn, getToken]);

  return (
    <AuthContext.Provider
      value={{
        user,
        authProblem,
        isLoading: !isLoaded || isLoading,
        isAuthenticated: !!user && isSignedIn === true,
        isAdmin: isAdminRole(user?.role),
        isSuperAdmin: user?.role === 'super_admin',
        isManager: user?.role === 'manager' || isAdminRole(user?.role),
        isAccountant: user?.role === 'accountant',
        isClient: user?.role === 'client',
        hasCapability: (capability) => user?.capabilities.includes(capability) === true,
        signOut: async (options) => {
          const clearAccount = () => {
            setUser(null);
            setAuthProblem(null);
          };
          // Keeping the user until Clerk confirms sign-out keeps the invitation
          // screen mounted so it can report a failed attempt and offer a retry.
          if (!options) clearAccount();
          clearAllDrafts();
          resetAnalytics();
          authApi.logout();
          try {
            await clerkSignOut(options);
            if (options) clearAccount();
          } catch (error) {
            if (!options && authProblem?.status === 403 && isMfaRequiredCode(authProblem.code)) {
              setUser(null);
              setAuthProblem({ ...authProblem, signOutFailed: true });
            }
            throw error;
          }
        },
        refreshUser,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  if (isDevMode) {
    return <DevAuthProvider>{children}</DevAuthProvider>;
  }
  return <ClerkAuthProvider>{children}</ClerkAuthProvider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}

// For components that can also render outside the provider (embedded dialogs,
// isolated tests). Undefined there; callers must treat that as signed out.
export function useOptionalAuth() {
  return useContext(AuthContext);
}
