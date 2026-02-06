# Clerk Authentication Setup Guide

A guide for integrating Clerk authentication in React + Rails applications, including dev mode bypass, JWT verification, role-based access, and invite-only user management.

---

## Table of Contents
1. [Overview & Architecture](#1-overview--architecture)
2. [Clerk Account Setup](#2-clerk-account-setup)
3. [Frontend Setup (React/Vite)](#3-frontend-setup-reactvite)
4. [Auth Context & Token Management](#4-auth-context--token-management)
5. [Protected Routes](#5-protected-routes)
6. [Backend Setup (Rails)](#6-backend-setup-rails)
7. [JWT Verification Service](#7-jwt-verification-service)
8. [Controller Authentication](#8-controller-authentication)
9. [User Model & Roles](#9-user-model--roles)
10. [Invite-Only User Management](#10-invite-only-user-management)
11. [Production Setup](#11-production-setup)
12. [Social Login (Google OAuth)](#12-social-login-google-oauth)
13. [Environment Variables](#13-environment-variables)
14. [Testing Without Auth](#14-testing-without-auth)
15. [Common Issues](#15-common-issues)

---

## 1. Overview & Architecture

### Authentication Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│   Browser   │────▶│    Clerk    │────▶│   Backend   │────▶│   Database   │
│  (React)    │     │   (Auth)    │     │   (Rails)   │     │ (PostgreSQL) │
└─────────────┘     └─────────────┘     └─────────────┘     └──────────────┘
       │                   │                   │
       │ 1. User signs in  │                   │
       │──────────────────▶│                   │
       │                   │                   │
       │ 2. JWT token      │                   │
       │◀──────────────────│                   │
       │                   │                   │
       │ 3. API request + Bearer token         │
       │──────────────────────────────────────▶│
       │                   │                   │
       │                   │ 4. Verify JWT via JWKS
       │                   │◀──────────────────│
       │                   │                   │
       │                   │ 5. JWT is valid   │
       │                   │──────────────────▶│
       │                   │                   │
       │                   │                   │ 6. Find/Create User
       │                   │                   │──────────────────────▶
       │                   │                   │
       │ 7. Response with user data            │
       │◀──────────────────────────────────────│
```

### Key Concepts

| Concept | Description |
|---------|-------------|
| **JWT** | JSON Web Token - signed token containing user info |
| **JWKS** | JSON Web Key Set - public keys to verify JWT signatures |
| **Clerk ID** | Unique user identifier from Clerk (e.g., `user_abc123`) |
| **Publishable Key** | Frontend key (safe to expose, starts with `pk_`) |
| **Secret Key** | Backend key (never expose, starts with `sk_`) |

---

## 2. Clerk Account Setup

### Steps:

1. Go to [clerk.com](https://clerk.com) and sign up
2. Create a new application
3. Name it (e.g., "MyApp Development")
4. Select sign-in methods (Email, Google, etc.)
5. Copy your keys from the dashboard

### Development vs Production:

Create **separate Clerk applications** for each environment:

| Environment | Clerk App Name | Purpose |
|-------------|---------------|---------|
| Development | MyApp Dev | Local testing, lax settings |
| Production | MyApp | Real users, strict settings |

### Recommended Sign-in Methods:

- ✅ Email address (always include)
- ✅ Google (most common SSO)
- ⬜ Apple (optional, iOS-heavy apps)
- ⬜ Microsoft (optional, enterprise apps)

---

## 3. Frontend Setup (React/Vite)

### Install Clerk:

```bash
npm install @clerk/clerk-react
```

### Environment Variables:

```bash
# .env.local (development)
VITE_CLERK_PUBLISHABLE_KEY=pk_test_abc123...

# .env.production (production)
VITE_CLERK_PUBLISHABLE_KEY=pk_live_xyz789...
```

### Main Entry Point (main.tsx):

The key pattern is **conditional ClerkProvider** - allowing the app to run without Clerk configured (dev mode).

```tsx
// src/main.tsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ClerkProvider } from '@clerk/clerk-react'
import App from './App'
import { AuthProvider } from './contexts/AuthContext'

const PUBLISHABLE_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const isClerkEnabled = Boolean(PUBLISHABLE_KEY && PUBLISHABLE_KEY !== 'YOUR_PUBLISHABLE_KEY')

// Log warning if Clerk is not configured
if (!isClerkEnabled) {
  console.warn('⚠️ Clerk not configured - running without authentication. Add VITE_CLERK_PUBLISHABLE_KEY to .env.local')
}

function Root() {
  // If Clerk is enabled, wrap with ClerkProvider
  if (isClerkEnabled) {
    return (
      <ClerkProvider publishableKey={PUBLISHABLE_KEY} afterSignOutUrl="/">
        <AuthProvider isClerkEnabled={true}>
          <App />
        </AuthProvider>
      </ClerkProvider>
    )
  }

  // Otherwise, just render the app without Clerk
  return (
    <AuthProvider isClerkEnabled={false}>
      <App />
    </AuthProvider>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)
```

---

## 4. Auth Context & Token Management

### AuthContext Pattern:

This context provides a consistent auth interface whether Clerk is enabled or not.

```tsx
// src/contexts/AuthContext.tsx
import { createContext, useContext, useEffect } from 'react'
import type { ReactNode } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { setAuthTokenGetter } from '../lib/api'

interface AuthContextType {
  isClerkEnabled: boolean
  isSignedIn: boolean
  isLoading: boolean
}

const AuthContext = createContext<AuthContextType>({ 
  isClerkEnabled: false,
  isSignedIn: false,
  isLoading: true
})

export function useAuthContext() {
  return useContext(AuthContext)
}

interface AuthProviderProps {
  children: ReactNode
  isClerkEnabled: boolean
}

// Inner provider that uses Clerk hooks (only rendered when Clerk is enabled)
function ClerkAuthProvider({ children }: { children: ReactNode }) {
  const { getToken, isLoaded, isSignedIn } = useAuth()

  useEffect(() => {
    // Set up the auth token getter for the API client
    setAuthTokenGetter(async () => {
      try {
        const token = await getToken()
        return token
      } catch (error) {
        console.error('Error getting auth token:', error)
        return null
      }
    })
  }, [getToken])

  return (
    <AuthContext.Provider value={{ 
      isClerkEnabled: true, 
      isSignedIn: isSignedIn ?? false,
      isLoading: !isLoaded
    }}>
      {children}
    </AuthContext.Provider>
  )
}

// Provider for when Clerk is not enabled (dev mode)
function NoAuthProvider({ children }: { children: ReactNode }) {
  useEffect(() => {
    // Set a no-op token getter when Clerk is disabled
    setAuthTokenGetter(async () => null)
  }, [])

  return (
    <AuthContext.Provider value={{ 
      isClerkEnabled: false, 
      isSignedIn: false,
      isLoading: false
    }}>
      {children}
    </AuthContext.Provider>
  )
}

// Main provider that conditionally uses Clerk
export function AuthProvider({ children, isClerkEnabled }: AuthProviderProps) {
  if (isClerkEnabled) {
    return <ClerkAuthProvider>{children}</ClerkAuthProvider>
  }
  return <NoAuthProvider>{children}</NoAuthProvider>
}
```

### API Client Token Injection:

```typescript
// src/lib/api.ts

// Store for the auth token getter function
let getAuthToken: (() => Promise<string | null>) | null = null;

// Set the auth token getter (called from AuthProvider)
export function setAuthTokenGetter(getter: () => Promise<string | null>) {
  getAuthToken = getter;
}

async function fetchApi<T>(
  endpoint: string,
  options: RequestInit = {},
  requireAuth: boolean = true
): Promise<ApiResponse<T>> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  };

  // Add auth token if available and required
  if (requireAuth && getAuthToken) {
    const token = await getAuthToken();
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }
  }

  const response = await fetch(`${API_BASE_URL}${endpoint}`, {
    ...options,
    headers,
  });

  // ... rest of fetch logic
}
```

---

## 5. Protected Routes

### ProtectedRoute Component:

Uses lazy loading to avoid importing Clerk hooks when not needed.

```tsx
// src/components/auth/ProtectedRoute.tsx
import { lazy, Suspense } from 'react'
import { useAuthContext } from '../../contexts/AuthContext'

interface ProtectedRouteProps {
  children: React.ReactNode
  requiredRole?: 'admin' | 'employee' | 'staff'
}

// Lazy load to avoid importing Clerk hooks when not needed
const ClerkProtectedContent = lazy(() => import('./ClerkProtectedContent'))

export default function ProtectedRoute({ children, requiredRole }: ProtectedRouteProps) {
  const { isClerkEnabled } = useAuthContext()

  // If Clerk is not enabled (dev mode), allow access without auth
  if (!isClerkEnabled) {
    return <>{children}</>
  }

  // When Clerk is enabled, use the protected route logic
  return (
    <Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center">
          <div className="animate-spin w-8 h-8 border-4 border-blue-500 border-t-transparent rounded-full" />
        </div>
      }
    >
      <ClerkProtectedContent requiredRole={requiredRole}>
        {children}
      </ClerkProtectedContent>
    </Suspense>
  )
}
```

### ClerkProtectedContent Component:

This component handles:
1. Waiting for Clerk to load
2. Verifying user with backend
3. Checking role requirements
4. Showing appropriate UI for each state

```tsx
// src/components/auth/ClerkProtectedContent.tsx
import { useEffect, useState, useRef } from 'react'
import { useAuth, useUser, RedirectToSignIn } from '@clerk/clerk-react'
import { api, setAuthTokenGetter } from '../../lib/api'

interface UserProfile {
  id: number
  email: string
  role: 'admin' | 'employee' | 'client'
  is_admin: boolean
  is_staff: boolean
}

interface ClerkProtectedContentProps {
  children: React.ReactNode
  requiredRole?: 'admin' | 'employee' | 'staff'
}

type AuthStatus = 'loading' | 'checking' | 'authorized' | 'unauthorized' | 'access_denied'

export default function ClerkProtectedContent({ children, requiredRole }: ClerkProtectedContentProps) {
  const { isLoaded, isSignedIn, getToken } = useAuth()
  const { user: clerkUser } = useUser()
  const [authStatus, setAuthStatus] = useState<AuthStatus>('loading')
  const [currentUser, setCurrentUser] = useState<UserProfile | null>(null)
  const authSetupRef = useRef(false)

  // Set up the auth token getter
  useEffect(() => {
    if (authSetupRef.current) return

    setAuthTokenGetter(async () => {
      try {
        return await getToken()
      } catch (error) {
        console.error('Failed to get auth token:', error)
        return null
      }
    })
    authSetupRef.current = true
  }, [getToken])

  // Verify user with backend
  useEffect(() => {
    const verifyUser = async () => {
      if (!isLoaded) return
      
      if (!isSignedIn) {
        setAuthStatus('unauthorized')
        return
      }

      setAuthStatus('checking')
      await new Promise(resolve => setTimeout(resolve, 100)) // Wait for token getter

      try {
        const email = clerkUser?.primaryEmailAddress?.emailAddress
        const response = await api.getCurrentUser(email)
        
        if (response.data) {
          const user = response.data.user
          setCurrentUser(user)

          // Check role if required
          if (requiredRole) {
            const hasAccess = 
              requiredRole === 'staff' ? user.is_staff :
              requiredRole === 'admin' ? user.is_admin :
              user.role === requiredRole

            if (!hasAccess) {
              setAuthStatus('access_denied')
              return
            }
          }

          setAuthStatus('authorized')
        } else {
          setAuthStatus('unauthorized')
        }
      } catch (error) {
        setAuthStatus('unauthorized')
      }
    }

    verifyUser()
  }, [isLoaded, isSignedIn, requiredRole, clerkUser])

  // Loading - Clerk not ready
  if (!isLoaded || authStatus === 'loading') {
    return <LoadingSpinner />
  }

  // Checking with backend
  if (authStatus === 'checking') {
    return <LoadingSpinner message="Verifying access..." />
  }

  // Not signed in - redirect
  if (authStatus === 'unauthorized' || !isSignedIn) {
    return <RedirectToSignIn />
  }

  // Access denied - wrong role
  if (authStatus === 'access_denied') {
    return <AccessDenied requiredRole={requiredRole} userEmail={currentUser?.email} />
  }

  // Authorized
  return <>{children}</>
}
```

### Usage in App.tsx:

```tsx
// src/App.tsx
import ProtectedRoute from './components/auth/ProtectedRoute'

function App() {
  return (
    <BrowserRouter>
      <Routes>
        {/* Public routes */}
        <Route path="/" element={<Home />} />
        
        {/* Protected admin routes - require staff role */}
        <Route
          path="/admin"
          element={
            <ProtectedRoute requiredRole="staff">
              <AdminLayout />
            </ProtectedRoute>
          }
        >
          <Route index element={<Dashboard />} />
          <Route path="users" element={<Users />} />
        </Route>

        {/* Admin-only routes */}
        <Route
          path="/admin/settings"
          element={
            <ProtectedRoute requiredRole="admin">
              <Settings />
            </ProtectedRoute>
          }
        />
      </Routes>
    </BrowserRouter>
  )
}
```

---

## 6. Backend Setup (Rails)

### Add Required Gems:

```ruby
# Gemfile
gem 'jwt'         # JWT decoding
gem 'httparty'    # Fetching JWKS
```

```bash
bundle install
```

### User Model:

```ruby
# db/migrate/xxx_create_users.rb
class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :clerk_id, null: false
      t.string :email, null: false
      t.string :first_name
      t.string :last_name
      t.string :role, default: 'employee', null: false

      t.timestamps
    end

    add_index :users, :clerk_id, unique: true
    add_index :users, :email, unique: true
  end
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  validates :clerk_id, presence: true, uniqueness: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: %w[admin employee client] }

  def admin?
    role == 'admin'
  end

  def employee?
    role == 'employee'
  end

  def staff?
    admin? || employee?
  end

  def full_name
    [first_name, last_name].compact.join(' ').presence || email.split('@').first
  end
end
```

---

## 7. JWT Verification Service

```ruby
# app/services/clerk_auth.rb
class ClerkAuth
  JWKS_CACHE_KEY = "clerk_jwks"
  JWKS_CACHE_TTL = 1.hour

  class << self
    # Verify a Clerk JWT token
    # @param token [String] The JWT token from the Authorization header
    # @return [Hash, nil] The decoded token payload, or nil if invalid
    def verify(token)
      return nil if token.blank?

      # In test environment, allow special test tokens
      if Rails.env.test? && token.start_with?("test_token_")
        return handle_test_token(token)
      end

      jwks = fetch_jwks
      return nil if jwks.nil?

      decoded = JWT.decode(token, nil, true, {
        algorithms: ["RS256"],
        jwks: jwks
      })

      decoded.first
    rescue JWT::DecodeError => e
      Rails.logger.warn("JWT decode error: #{e.message}")
      nil
    rescue JWT::ExpiredSignature
      Rails.logger.debug("JWT token expired")
      nil
    end

    private

    def fetch_jwks
      # Try cache first
      cached = Rails.cache.read(JWKS_CACHE_KEY)
      return cached if cached.present?

      # Fetch from Clerk
      jwks_uri = jwks_url
      return nil unless jwks_uri

      response = HTTParty.get(jwks_uri, timeout: 5)

      if response.success?
        jwks = response.parsed_response
        Rails.cache.write(JWKS_CACHE_KEY, jwks, expires_in: JWKS_CACHE_TTL)
        jwks
      else
        Rails.logger.error("Failed to fetch Clerk JWKS: #{response.code}")
        nil
      end
    rescue HTTParty::Error, Timeout::Error => e
      Rails.logger.error("Error fetching Clerk JWKS: #{e.message}")
      nil
    end

    def jwks_url
      # Use CLERK_JWKS_URL directly if set
      jwks = ENV.fetch("CLERK_JWKS_URL", nil)
      return jwks if jwks.present?

      # Fallback: build from CLERK_ISSUER
      issuer = ENV.fetch("CLERK_ISSUER", nil)
      if issuer.present?
        "#{issuer}/.well-known/jwks.json"
      else
        Rails.logger.warn("Neither CLERK_JWKS_URL nor CLERK_ISSUER configured")
        nil
      end
    end

    # For testing: test_token_<user_id> returns that user's info
    def handle_test_token(token)
      user_id = token.gsub("test_token_", "")
      user = User.find_by(id: user_id)
      
      if user
        {
          "sub" => user.clerk_id || "test_clerk_#{user.id}",
          "email" => user.email,
          "first_name" => user.first_name,
          "last_name" => user.last_name
        }
      end
    end
  end
end
```

---

## 8. Controller Authentication

### ClerkAuthenticatable Concern:

```ruby
# app/controllers/concerns/clerk_authenticatable.rb
module ClerkAuthenticatable
  extend ActiveSupport::Concern

  private

  # Require authentication - call this in before_action
  def authenticate_user!
    header = request.headers["Authorization"]

    unless header.present?
      render_unauthorized("Missing authorization header")
      return
    end

    token = header.split(" ").last
    decoded = ClerkAuth.verify(token)

    unless decoded
      render_unauthorized("Invalid or expired token")
      return
    end

    # Extract user info from the token
    clerk_id = decoded["sub"]
    email = decoded["email"] || decoded["primary_email_address"]
    first_name = decoded["first_name"]
    last_name = decoded["last_name"]

    # Find or create user
    @current_user = find_or_create_user(
      clerk_id: clerk_id,
      email: email,
      first_name: first_name,
      last_name: last_name
    )

    unless @current_user
      render_unauthorized("Unable to authenticate user")
    end
  end

  # Optional authentication - sets current_user if present, doesn't require it
  def authenticate_user_optional
    header = request.headers["Authorization"]
    return unless header.present?

    token = header.split(" ").last
    decoded = ClerkAuth.verify(token)
    return unless decoded

    clerk_id = decoded["sub"]
    @current_user = User.find_by(clerk_id: clerk_id)
  end

  def current_user
    @current_user
  end

  # Authorization helpers
  def require_admin!
    authenticate_user! unless @current_user
    return if performed?

    unless @current_user&.admin?
      render_forbidden("Admin access required")
    end
  end

  def require_staff!
    authenticate_user! unless @current_user
    return if performed?

    unless @current_user&.staff?
      render_forbidden("Staff access required")
    end
  end

  private

  def find_or_create_user(clerk_id:, email:, first_name:, last_name:)
    # Implementation depends on your user management strategy
    # See "Invite-Only User Management" section
  end

  def render_unauthorized(message = "Unauthorized")
    render json: { error: message }, status: :unauthorized
  end

  def render_forbidden(message = "Forbidden")
    render json: { error: message }, status: :forbidden
  end
end
```

### Base Controller:

```ruby
# app/controllers/api/v1/base_controller.rb
module Api
  module V1
    class BaseController < ApplicationController
      include ClerkAuthenticatable

      protect_from_forgery with: :null_session
      skip_before_action :verify_authenticity_token
    end
  end
end
```

### Protected Controller Example:

```ruby
# app/controllers/api/v1/admin/users_controller.rb
module Api
  module V1
    module Admin
      class UsersController < BaseController
        before_action :authenticate_user!
        before_action :require_admin!

        def index
          users = User.all.order(:created_at)
          render json: { users: users }
        end

        def create
          # Only admins can create users (invite-only)
          user = User.new(user_params)
          if user.save
            render json: { user: user }, status: :created
          else
            render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
```

---

## 9. User Model & Roles

### Role Definitions:

| Role | Access | Description |
|------|--------|-------------|
| `admin` | Full | All features, user management |
| `employee` | Staff | Day-to-day operations, no user mgmt |
| `client` | Limited | View own data only |

### Role Helpers:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  ROLES = %w[admin employee client].freeze

  validates :role, inclusion: { in: ROLES }

  def admin?
    role == 'admin'
  end

  def employee?
    role == 'employee'
  end

  def client?
    role == 'client'
  end

  # "Staff" = admin OR employee (internal users)
  def staff?
    admin? || employee?
  end

  # Computed attributes for frontend
  def is_admin
    admin?
  end

  def is_staff
    staff?
  end
end
```

---

## 10. Invite-Only User Management

### The Pattern:

Instead of auto-creating users on first sign-in, require admins to invite users first.

```
1. Admin creates User record (email + role)
2. User receives invitation email
3. User signs up with Clerk (using invited email)
4. Backend links Clerk ID to existing User record
```

### find_or_create_user for Invite-Only:

```ruby
def find_or_create_user(clerk_id:, email:, first_name:, last_name:)
  return nil if clerk_id.blank?

  # First try to find by clerk_id (returning user)
  user = User.find_by(clerk_id: clerk_id)
  
  if user
    # Update profile info if changed
    updates = {}
    updates[:email] = email if email.present? && email != user.email
    updates[:first_name] = first_name if first_name.present?
    updates[:last_name] = last_name if last_name.present?
    user.update(updates) if updates.any?
    return user
  end

  # Try to find by email (invited user signing in for first time)
  if email.present?
    user = User.find_by("LOWER(email) = ?", email.downcase)
    
    if user
      # Link the Clerk ID to this invited user
      user.update(clerk_id: clerk_id, first_name: first_name, last_name: last_name)
      return user
    end
  end

  # SPECIAL CASE: First user ever = auto-create as admin
  if User.count.zero?
    user_email = email.presence || "#{clerk_id}@placeholder.local"
    return User.create(
      clerk_id: clerk_id,
      email: user_email,
      first_name: first_name,
      last_name: last_name,
      role: "admin"
    )
  end

  # User not invited - return nil (will trigger 401)
  nil
end
```

### Invite User Endpoint:

```ruby
# app/controllers/api/v1/admin/users_controller.rb
def create
  user = User.new(
    email: params[:email],
    role: params[:role] || 'employee',
    clerk_id: "pending_#{SecureRandom.uuid}" # Placeholder until user signs up
  )

  if user.save
    # Optionally send invitation email
    UserMailer.invitation_email(user: user, invited_by: current_user).deliver_later
    render json: { user: user }, status: :created
  else
    render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
  end
end
```

---

## 11. Production Setup

### Create Production Clerk App:

1. In Clerk dashboard, create new application for production
2. Configure:
   - **Application name**: Your App (not "Your App Dev")
   - **Deployment**: Production
   - **Allowed origins**: `https://yourdomain.com`

### Configure Custom Domain (Optional):

1. Go to Clerk dashboard → **Configure** → **Domains**
2. Add your domain: `clerk.yourdomain.com` or `auth.yourdomain.com`
3. Add the DNS records Clerk provides
4. Wait for verification

### Find JWKS URL:

In Clerk dashboard → **API Keys** → Click on **Advanced**:

```
JWKS URL: https://clerk.yourdomain.com/.well-known/jwks.json
   - or -
JWKS URL: https://your-app.clerk.accounts.dev/.well-known/jwks.json
```

---

## 12. Social Login (Google OAuth)

### Enable in Clerk:

1. Clerk dashboard → **User & Authentication** → **Social Connections**
2. Enable **Google**
3. Choose "Use Clerk's development credentials" OR configure your own

### Configure Your Own Google Credentials:

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create or select a project
3. Go to **APIs & Services** → **Credentials**
4. Click **Create Credentials** → **OAuth client ID**
5. Application type: **Web application**
6. Name: "Clerk Auth" or your app name

#### Authorized JavaScript Origins:
```
https://yourdomain.com
https://clerk.yourdomain.com
```

#### Authorized Redirect URIs:
```
https://clerk.yourdomain.com/v1/oauth_callback
   - or for development -
https://your-app.clerk.accounts.dev/v1/oauth_callback
```

7. Copy Client ID and Client Secret to Clerk dashboard

---

## 13. Environment Variables

### Frontend (.env):

```bash
# Development
VITE_CLERK_PUBLISHABLE_KEY=pk_test_abc123...
VITE_API_URL=http://localhost:3000

# Production
VITE_CLERK_PUBLISHABLE_KEY=pk_live_xyz789...
VITE_API_URL=https://api.yourdomain.com
```

### Backend (Rails):

```bash
# Development (.env)
CLERK_JWKS_URL=https://your-app.clerk.accounts.dev/.well-known/jwks.json
# OR
CLERK_ISSUER=https://your-app.clerk.accounts.dev

# Production (Render/Heroku env vars)
CLERK_JWKS_URL=https://clerk.yourdomain.com/.well-known/jwks.json
```

### Environment Variable Reference:

| Variable | Where | Purpose |
|----------|-------|---------|
| `VITE_CLERK_PUBLISHABLE_KEY` | Frontend | Initialize ClerkProvider |
| `CLERK_JWKS_URL` | Backend | Verify JWT signatures |
| `CLERK_ISSUER` | Backend | Alternative to JWKS_URL (builds URL from issuer) |
| `CLERK_SECRET_KEY` | Backend | **NOT NEEDED** for JWT verification (JWKS is public) |

---

## 14. Testing Without Auth

### Development Mode:

When `VITE_CLERK_PUBLISHABLE_KEY` is not set:

1. ClerkProvider is not rendered
2. ProtectedRoute allows all access
3. API calls don't include Authorization header
4. Backend should handle missing auth gracefully (or skip auth in dev)

### Rails Test Tokens:

The `ClerkAuth.verify` service supports test tokens:

```ruby
# In tests, use: Authorization: Bearer test_token_1
# This returns the User with ID 1's info

# Usage in RSpec:
it 'authenticates with test token' do
  user = create(:user)
  get '/api/v1/me', headers: { 'Authorization' => "Bearer test_token_#{user.id}" }
  expect(response).to be_successful
end
```

---

## 15. Guest Checkout Pattern (E-commerce / Ordering Apps)

Not every user needs an account. For ordering, e-commerce, or event registration apps, **guest checkout** reduces friction and keeps Clerk costs low.

### When to Use Guest Checkout

| Use Case | Auth Approach |
|----------|--------------|
| Restaurant ordering | Guest checkout (name, phone, email) |
| Event ticket purchase | Guest checkout |
| Admin/staff dashboard | Full Clerk auth with roles |
| SaaS with user data | Full Clerk auth |
| Repeat customer features | Optional Clerk account |

### Architecture: Clerk for Admins, Guest for Customers

```
Restaurant Admin/Staff → Clerk auth (invite-only, roles)
Customer placing order  → Guest checkout (no account needed)
                          └── Optional: "Save info for next time?" → creates Clerk account
```

### Backend Implementation

```ruby
# app/controllers/api/v1/base_controller.rb
class Api::V1::BaseController < ApplicationController
  include ClerkAuthenticatable

  private

  # Use for admin/staff endpoints
  # before_action :require_staff!
  # before_action :require_admin!

  # Use for customer endpoints that work with OR without auth
  def current_customer
    if request.headers['Authorization'].present?
      authenticate_user!  # Returns Clerk user if valid token
      current_user
    else
      nil  # Guest checkout — no auth required
    end
  end
end

# app/controllers/api/v1/orders_controller.rb
class Api::V1::OrdersController < Api::V1::BaseController
  # No before_action auth — guests can order!

  def create
    @order = @restaurant.orders.new(order_params)
    @order.user = current_customer  # nil for guests, User for logged-in
    # ... process order
  end
end

# app/controllers/api/v1/admin/orders_controller.rb
class Api::V1::Admin::OrdersController < Api::V1::BaseController
  before_action :require_staff!  # Only staff can manage orders

  def index
    @orders = @restaurant.orders.recent
  end
end
```

### Frontend Implementation

```tsx
// Guest checkout form — no Clerk required
const GuestCheckoutForm = () => {
  const [customerInfo, setCustomerInfo] = useState({
    name: '',
    phone: '',
    email: '',
  });

  return (
    <form>
      <input placeholder="Your name" required />
      <input placeholder="Phone number" required />
      <input placeholder="Email (for receipt)" required />
      {/* No sign-in needed! */}
    </form>
  );
};

// Optional: After checkout, offer account creation
const PostCheckoutUpsell = () => {
  const { isSignedIn } = useAuth();

  if (isSignedIn) return null;

  return (
    <div>
      <p>Want to save your info for faster checkout next time?</p>
      <SignUpButton mode="modal">
        <button>Create Account</button>
      </SignUpButton>
    </div>
  );
};
```

### Cost Optimization

Clerk charges per Monthly Active User (MAU). With guest checkout:
- **Admin/staff only:** 5-20 MAUs per restaurant (practically free)
- **With optional customer accounts:** Only customers who CHOOSE to sign up count
- **Without this pattern:** Every customer who orders = 1 MAU = $0.02 after free tier

For a multi-tenant SaaS with many restaurants, this saves hundreds/month.

---

## 16. Common Issues

### "Missing authorization header" on every request

**Cause**: Token getter not set up, or ClerkProvider not wrapping app  
**Fix**: Ensure `setAuthTokenGetter` is called in AuthContext

### "Invalid or expired token"

**Cause**: JWKS not fetched, wrong CLERK_JWKS_URL  
**Fix**: 
1. Check CLERK_JWKS_URL is correct
2. Verify you can access `https://your-jwks-url/.well-known/jwks.json` in browser
3. Check Rails cache is working (JWKS is cached)

### User created but role is wrong

**Cause**: Auto-creation assigns default role  
**Fix**: Use invite-only pattern - create user with role before they sign up

### CORS error on /me endpoint

**Cause**: Backend CORS not configured for frontend origin  
**Fix**: Add frontend URL to Rails CORS config

```ruby
# config/initializers/cors.rb
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("FRONTEND_URL", "http://localhost:5173")
    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      credentials: true
  end
end
```

### "Unable to authenticate user" for invited user

**Cause**: Email case mismatch, or user not created with correct email  
**Fix**: Use case-insensitive email lookup

```ruby
user = User.find_by("LOWER(email) = ?", email.downcase)
```

### Token works in Postman but not in browser

**Cause**: CORS blocking preflight, or Authorization header stripped  
**Fix**: 
1. Check browser Network tab for preflight OPTIONS request
2. Ensure CORS allows Authorization header

---

## Quick Reference

### Checklist for New Project:

- [ ] Create Clerk application (dev + production)
- [ ] Install `@clerk/clerk-react` in frontend
- [ ] Set up `VITE_CLERK_PUBLISHABLE_KEY`
- [ ] Create `AuthContext` with conditional ClerkProvider
- [ ] Create `ProtectedRoute` component
- [ ] Add `jwt` and `httparty` gems to Rails
- [ ] Create `ClerkAuth` service
- [ ] Create `ClerkAuthenticatable` concern
- [ ] Add User model with `clerk_id`, `email`, `role`
- [ ] Set up `CLERK_JWKS_URL` in backend
- [ ] Test sign-in flow end-to-end
- [ ] Configure production Clerk app
- [ ] Set up social login (Google OAuth)

### Key Files:

| File | Purpose |
|------|---------|
| `src/main.tsx` | Conditional ClerkProvider |
| `src/contexts/AuthContext.tsx` | Token management |
| `src/components/auth/ProtectedRoute.tsx` | Route protection |
| `src/components/auth/ClerkProtectedContent.tsx` | Backend verification |
| `app/services/clerk_auth.rb` | JWT verification |
| `app/controllers/concerns/clerk_authenticatable.rb` | Controller auth |
