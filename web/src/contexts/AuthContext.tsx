/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { useAuth as useClerkAuth } from '@clerk/clerk-react';
import { ApiError, authApi, setAuthToken, setAuthTokenProvider } from '@/services/api';

export type StaffCapability =
  | 'staff_workspace'
  | 'payroll_operations'
  | 'manage_client_configuration'
  | 'manage_organization'
  | 'manage_platform';

type CapabilityMap = Record<StaffCapability, boolean>;

interface User {
  id: number;
  email: string;
  name: string;
  role: string;
  organization_id?: number;
  organization_name?: string;
  company_id: number;
  company_name: string;
  assigned_company_ids: number[];
  capabilities: CapabilityMap;
}

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  isAdmin: boolean;
  isSuperAdmin: boolean;
  isManager: boolean;
  isAccountant: boolean;
  isClient: boolean;
  can: (capability: StaffCapability) => boolean;
  signOut: () => Promise<void>;
  refreshUser: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);
type AuthResponseUser = Awaited<ReturnType<typeof authApi.me>>['user'];

function mapAuthUser(user: AuthResponseUser): User {
  const isAdmin = isAdminRole(user.role);
  const fallbackCapabilities: CapabilityMap = {
    staff_workspace: !['client'].includes(user.role),
    payroll_operations: !['client'].includes(user.role),
    manage_client_configuration: user.role === 'manager' || isAdmin,
    manage_organization: isAdmin,
    manage_platform: user.role === 'super_admin',
  };

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
    capabilities: { ...fallbackCapabilities, ...user.capabilities },
  };
}

// Dev mode bypass — when VITE_CLERK_PUBLISHABLE_KEY is not set
const isDevMode = !import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;
const authEnabled = import.meta.env.VITE_AUTH_ENABLED === 'true';

function isAdminRole(role?: string) {
  return role === 'admin' || role === 'org_admin' || role === 'super_admin';
}

function canUser(user: User | null, capability: StaffCapability): boolean {
  return user?.capabilities[capability] === true;
}

function DevAuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
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
      .then((res) => setUser(mapAuthUser(res.user)))
      .catch(() => setUser(null))
      .finally(() => setIsLoading(false));
  }, []);

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isAuthenticated: !!user,
        isAdmin: canUser(user, 'manage_organization'),
        isSuperAdmin: canUser(user, 'manage_platform'),
        isManager: canUser(user, 'manage_client_configuration'),
        isAccountant: user?.role === 'accountant',
        isClient: user?.role === 'client',
        can: (capability) => canUser(user, capability),
        signOut: async () => setUser(null),
        refreshUser: async () => {
          const res = await authApi.me();
          setUser(mapAuthUser(res.user));
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
  const [isLoading, setIsLoading] = useState(true);
  const [backendUnauthorized, setBackendUnauthorized] = useState(false);

  useEffect(() => {
    if (!isSignedIn) {
      setAuthTokenProvider(null);
      setAuthToken(null);
      return;
    }

    // Always fetch a fresh Clerk token before API requests.
    setAuthTokenProvider(() => getToken());
  }, [isSignedIn, getToken]);

  const refreshUser = useCallback(async () => {
    if (!isSignedIn) {
      setUser(null);
      setBackendUnauthorized(false);
      setIsLoading(false);
      return;
    }

    if (backendUnauthorized) {
      setIsLoading(false);
      return;
    }

    try {
      const token = await getToken();
      if (token) {
        // Set token for API calls
        setAuthToken(token);
      }

      const res = await authApi.me();
      setUser(mapAuthUser(res.user));
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        // Clerk session exists but backend rejected user (e.g. not provisioned/invited).
        // Sign out locally to prevent redirect/auth polling loops.
        setBackendUnauthorized(true);
        setAuthToken(null);
        await clerkSignOut();
      } else {
        console.error('Failed to load user:', err);
      }
      setUser(null);
    } finally {
      setIsLoading(false);
    }
  }, [backendUnauthorized, isSignedIn, getToken, clerkSignOut]);

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
      const token = await getToken();
      if (token) {
        setAuthToken(token);
      }
    }, 50000); // Refresh every 50s

    return () => clearInterval(interval);
  }, [isSignedIn, getToken]);

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading: !isLoaded || isLoading,
        isAuthenticated: !!user && isSignedIn === true,
        isAdmin: canUser(user, 'manage_organization'),
        isSuperAdmin: canUser(user, 'manage_platform'),
        isManager: canUser(user, 'manage_client_configuration'),
        isAccountant: user?.role === 'accountant',
        isClient: user?.role === 'client',
        can: (capability) => canUser(user, capability),
        signOut: async () => {
          setUser(null);
          await clerkSignOut();
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
