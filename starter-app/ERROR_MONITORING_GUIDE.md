# Error Monitoring Guide (Sentry)

A comprehensive guide for setting up Sentry error tracking in Rails + React apps. Covers installation, user context, performance monitoring, custom error boundaries, alerts, and environment-specific configuration.

---

## Table of Contents
1. [Overview](#1-overview)
2. [Sentry Account Setup](#2-sentry-account-setup)
3. [Rails: Backend Setup](#3-rails-backend-setup)
4. [React: Frontend Setup](#4-react-frontend-setup)
5. [User Context (Clerk Integration)](#5-user-context-clerk-integration)
6. [Source Maps for React](#6-source-maps-for-react)
7. [Performance Monitoring](#7-performance-monitoring)
8. [Custom Error Boundaries](#8-custom-error-boundaries)
9. [Alert Rules and Notifications](#9-alert-rules-and-notifications)
10. [Environment-Specific Configuration](#10-environment-specific-configuration)
11. [Advanced Patterns](#11-advanced-patterns)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Overview

### Why Sentry?

Sentry captures errors in real-time, with full stack traces, user context, and breadcrumbs. Without it, production errors are invisible until a user complains.

```
┌──────────┐  Error occurs    ┌──────────┐   Reports to    ┌──────────┐
│  React   │ ───────────────▶ │  Sentry  │ ───────────────▶ │  Slack/  │
│  Client  │                  │  Cloud   │                  │  Email   │
└──────────┘                  └──────────┘                  └──────────┘
                                   ▲
┌──────────┐  Error occurs         │
│  Rails   │ ──────────────────────┘
│  API     │
└──────────┘
```

### What Sentry Captures

| Feature | Rails | React |
|---------|-------|-------|
| Unhandled exceptions | ✅ Automatic | ✅ Automatic |
| API errors (500s) | ✅ Automatic | — |
| JS runtime errors | — | ✅ Automatic |
| Render errors | — | ✅ With ErrorBoundary |
| Performance traces | ✅ Optional | ✅ Optional |
| User context | ✅ Manual setup | ✅ Manual setup |
| Breadcrumbs | ✅ Automatic | ✅ Automatic |
| Source maps | — | ✅ Upload required |

### The Shimizu Way

> **Set up Sentry before your first production deploy.** It takes 15 minutes and saves hours of debugging. The free tier (5K errors/month) is generous enough for most starter apps. Don't wait until production breaks to start monitoring.

---

## 2. Sentry Account Setup

### 2.1 Create Account

1. Go to [sentry.io](https://sentry.io) and create an account
2. Create an **Organization** (e.g., `shimizu-technology`)
3. Create **two projects**:
   - `myapp-api` (Platform: Ruby → Rails)
   - `myapp-frontend` (Platform: JavaScript → React)

### 2.2 Get Your DSNs

After creating each project, Sentry gives you a **DSN** (Data Source Name). You'll need one for each:

```
# Rails DSN (looks like this)
https://abc123@o123456.ingest.sentry.io/1234567

# React DSN (different project, different DSN)
https://def456@o123456.ingest.sentry.io/7654321
```

### 2.3 Create Auth Token (for source maps)

1. Go to **Settings** → **Auth Tokens**
2. Create a token with `project:releases` and `org:read` scopes
3. Save this for CI/CD source map uploads

---

## 3. Rails: Backend Setup

### 3.1 Install Gems

```ruby
# Gemfile
gem 'sentry-ruby', '~> 5.0'
gem 'sentry-rails', '~> 5.0'
```

```bash
bundle install
```

### 3.2 Configure Sentry

```ruby
# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']

  # Set environment
  config.environment = Rails.env

  # Sample rate: 1.0 = 100% of errors (recommended for most apps)
  config.sample_rate = 1.0

  # Performance monitoring sample rate
  # 0.1 = 10% of transactions (adjust based on traffic)
  config.traces_sample_rate = Rails.env.production? ? 0.1 : 1.0

  # Don't send errors in development (optional — some prefer to test locally)
  config.enabled_environments = %w[production staging]

  # Filter sensitive data
  config.before_send = lambda { |event, hint|
    # Strip sensitive params
    event.request&.data&.delete('password')
    event.request&.data&.delete('credit_card')
    event.request&.data&.delete('token')
    event
  }

  # Add release version for tracking deployments
  config.release = ENV.fetch('GIT_SHA', `git rev-parse HEAD`.strip)

  # Breadcrumbs: capture up to 100 (default is 100)
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Exclude common non-actionable errors
  config.excluded_exceptions += [
    'ActionController::RoutingError',       # 404s
    'ActiveRecord::RecordNotFound',          # 404s
    'ActionController::InvalidAuthenticityToken',
    'ActionController::BadRequest',
    'CGI::Session::CookieStore::TamperedWithCookie'
  ]

  # Set server name
  config.server_name = ENV.fetch('RENDER_SERVICE_NAME', Socket.gethostname)
end
```

### 3.3 Add User Context

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  before_action :set_sentry_context

  private

  def set_sentry_context
    return unless current_user

    Sentry.set_user(
      id: current_user.id,
      email: current_user.email,
      username: current_user.name,
      clerk_id: current_user.clerk_user_id
    )
  end
end
```

### 3.4 Manual Error Capture

```ruby
# Capture errors you handle gracefully but want to track
def process_payment(order)
  PaymentService.charge(order)
rescue Stripe::CardError => e
  # Handle gracefully for the user
  order.update!(status: 'payment_failed')

  # But still report to Sentry with context
  Sentry.capture_exception(e, extra: {
    order_id: order.id,
    amount: order.total,
    customer_id: order.user_id
  })

  render json: { error: 'Payment failed' }, status: :unprocessable_entity
end
```

### 3.5 Capture Messages (Non-Exception Events)

```ruby
# Track important events that aren't errors
Sentry.capture_message(
  "Large order placed: $#{order.total}",
  level: :info,
  extra: { order_id: order.id, items_count: order.items.count }
)

# Track warnings
if queue_depth > 1000
  Sentry.capture_message(
    "Job queue depth is high: #{queue_depth}",
    level: :warning,
    tags: { queue: 'default' }
  )
end
```

### 3.6 Tags and Context

```ruby
# Add tags (indexed, searchable)
Sentry.set_tags(
  restaurant_id: current_restaurant.id,
  plan: current_restaurant.plan_name
)

# Add extra context (not indexed, but visible on error detail)
Sentry.set_extras(
  request_id: request.request_id,
  user_agent: request.user_agent,
  ip: request.remote_ip
)

# Scoped context (for a specific block)
Sentry.with_scope do |scope|
  scope.set_tags(operation: 'bulk_import')
  scope.set_extras(batch_size: records.count)

  import_records(records)
end
```

---

## 4. React: Frontend Setup

### 4.1 Install Sentry

```bash
npm install @sentry/react
```

### 4.2 Initialize Sentry

```typescript
// src/main.tsx (or src/index.tsx)
import React from 'react';
import ReactDOM from 'react-dom/client';
import * as Sentry from '@sentry/react';
import App from './App';

// Initialize Sentry BEFORE rendering the app
Sentry.init({
  dsn: import.meta.env.VITE_SENTRY_DSN,

  // Environment
  environment: import.meta.env.MODE, // 'development', 'production', 'staging'

  // Only send errors in production/staging
  enabled: import.meta.env.PROD,

  // Release version (set during build)
  release: import.meta.env.VITE_SENTRY_RELEASE,

  // Error sampling: 1.0 = capture 100% of errors
  sampleRate: 1.0,

  // Performance monitoring: capture 10% of transactions
  tracesSampleRate: 0.1,

  // Session replay: capture 10% of sessions, 100% on error
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,

  integrations: [
    Sentry.browserTracingIntegration(),
    Sentry.replayIntegration(),
  ],

  // Filter out noisy errors
  beforeSend(event) {
    // Ignore ResizeObserver errors (benign browser bug)
    if (event.exception?.values?.[0]?.value?.includes('ResizeObserver')) {
      return null;
    }

    // Ignore network errors from extensions
    if (event.exception?.values?.[0]?.value?.includes('chrome-extension://')) {
      return null;
    }

    return event;
  },

  // Don't send PII by default
  sendDefaultPii: false,
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
```

### 4.3 Error Boundary

Wrap your app (or specific sections) in Sentry's error boundary:

```tsx
// src/App.tsx
import * as Sentry from '@sentry/react';
import { ClerkProvider } from '@clerk/clerk-react';
import { AppRouter } from './router';
import { ErrorFallback } from './shared/components/ErrorFallback';

export default function App() {
  return (
    <Sentry.ErrorBoundary fallback={ErrorFallback} showDialog>
      <ClerkProvider publishableKey={import.meta.env.VITE_CLERK_PUBLISHABLE_KEY}>
        <AppRouter />
      </ClerkProvider>
    </Sentry.ErrorBoundary>
  );
}
```

### 4.4 Manual Error Capture in React

```typescript
// Capture errors in try/catch blocks
async function placeOrder(orderData: OrderInput) {
  try {
    const response = await api.post('/orders', orderData);
    return response.data;
  } catch (error) {
    // Report to Sentry with context
    Sentry.captureException(error, {
      tags: { action: 'place_order' },
      extra: {
        orderData,
        userId: user?.id,
      },
    });

    // Still handle gracefully for the user
    toast.error('Failed to place order. Please try again.');
    throw error;
  }
}
```

### 4.5 Add Breadcrumbs

```typescript
// Add custom breadcrumbs for debugging context
function addToCart(item: MenuItem) {
  Sentry.addBreadcrumb({
    category: 'cart',
    message: `Added ${item.name} to cart`,
    level: 'info',
    data: {
      itemId: item.id,
      price: item.price,
    },
  });

  // ... actual add to cart logic
}

function navigateToCheckout() {
  Sentry.addBreadcrumb({
    category: 'navigation',
    message: 'User navigated to checkout',
    level: 'info',
    data: {
      cartTotal: cart.total,
      itemCount: cart.items.length,
    },
  });

  navigate('/checkout');
}
```

---

## 5. User Context (Clerk Integration)

### 5.1 React: Set User on Auth

```typescript
// src/shared/providers/SentryUserProvider.tsx
import { useEffect } from 'react';
import { useUser, useAuth } from '@clerk/clerk-react';
import * as Sentry from '@sentry/react';

export function SentryUserProvider({ children }: { children: React.ReactNode }) {
  const { user, isLoaded } = useUser();
  const { isSignedIn } = useAuth();

  useEffect(() => {
    if (!isLoaded) return;

    if (isSignedIn && user) {
      Sentry.setUser({
        id: user.id,
        email: user.primaryEmailAddress?.emailAddress,
        username: user.fullName || user.username || undefined,
      });
    } else {
      // Clear user context on sign out
      Sentry.setUser(null);
    }
  }, [isLoaded, isSignedIn, user]);

  return <>{children}</>;
}
```

```tsx
// src/App.tsx — add the provider
export default function App() {
  return (
    <Sentry.ErrorBoundary fallback={ErrorFallback}>
      <ClerkProvider publishableKey={import.meta.env.VITE_CLERK_PUBLISHABLE_KEY}>
        <SentryUserProvider>
          <AppRouter />
        </SentryUserProvider>
      </ClerkProvider>
    </Sentry.ErrorBoundary>
  );
}
```

### 5.2 Rails: Set User in Controllers

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  before_action :set_sentry_user

  private

  def set_sentry_user
    if current_user
      Sentry.set_user(
        id: current_user.id,
        email: current_user.email,
        username: current_user.name,
        ip_address: request.remote_ip
      )
    else
      Sentry.set_user(
        ip_address: request.remote_ip
      )
    end
  end
end
```

---

## 6. Source Maps for React

### 6.1 Why Source Maps?

Without source maps, Sentry shows minified code in stack traces — useless for debugging:

```
// Without source maps:
TypeError: Cannot read property 'map' of undefined
  at e.render (app.3f2a1b.js:1:23456)

// With source maps:
TypeError: Cannot read property 'map' of undefined
  at OrderList.render (src/features/orders/OrderList.tsx:42:18)
```

### 6.2 Vite Configuration

```typescript
// vite.config.ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { sentryVitePlugin } from '@sentry/vite-plugin';

export default defineConfig({
  plugins: [
    react(),
    // Sentry plugin uploads source maps during build
    sentryVitePlugin({
      org: 'shimizu-technology',
      project: 'myapp-frontend',
      authToken: process.env.SENTRY_AUTH_TOKEN,

      // Only upload in production builds
      disable: process.env.NODE_ENV !== 'production',

      sourcemaps: {
        // Delete source maps after upload (don't serve them publicly)
        filesToDeleteAfterUpload: ['./dist/**/*.map'],
      },

      release: {
        // Use git SHA as release version
        name: process.env.VITE_SENTRY_RELEASE || process.env.COMMIT_REF,
      },
    }),
  ],
  build: {
    sourcemap: true, // Generate source maps for Sentry
  },
});
```

### 6.3 Install the Vite Plugin

```bash
npm install @sentry/vite-plugin --save-dev
```

### 6.4 Netlify Build Configuration

```toml
# netlify.toml
[build]
  command = "npm run build"
  publish = "dist"

[build.environment]
  SENTRY_AUTH_TOKEN = "" # Set in Netlify UI, not here!
  VITE_SENTRY_RELEASE = "" # Auto-set by Netlify (COMMIT_REF)
```

Set the actual `SENTRY_AUTH_TOKEN` in **Netlify Dashboard** → **Site settings** → **Environment variables** (never commit tokens to git).

### 6.5 GitHub Actions Alternative

```yaml
# .github/workflows/deploy.yml
- name: Build with source maps
  run: npm run build
  env:
    VITE_SENTRY_DSN: ${{ secrets.VITE_SENTRY_DSN }}
    VITE_SENTRY_RELEASE: ${{ github.sha }}
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
    SENTRY_ORG: shimizu-technology
    SENTRY_PROJECT: myapp-frontend
```

---

## 7. Performance Monitoring

### 7.1 Rails: Transaction Tracing

Sentry automatically traces Rails requests. You can add custom spans:

```ruby
# app/services/order_service.rb
class OrderService
  def self.create(user, items)
    Sentry.with_child_span(op: 'order.create', description: 'Create order with items') do
      order = nil

      Sentry.with_child_span(op: 'db', description: 'Create order record') do
        order = Order.create!(user: user, status: 'pending')
      end

      Sentry.with_child_span(op: 'db', description: 'Create order items') do
        items.each do |item|
          order.order_items.create!(item)
        end
      end

      Sentry.with_child_span(op: 'calculation', description: 'Calculate totals') do
        order.calculate_total!
      end

      Sentry.with_child_span(op: 'external', description: 'Process payment') do
        PaymentService.charge(order)
      end

      order
    end
  end
end
```

### 7.2 React: Component Profiling

```tsx
// Wrap components to track render performance
import * as Sentry from '@sentry/react';

// Method 1: HOC
const ProfiledOrderList = Sentry.withProfiler(OrderList);

// Method 2: In JSX
function App() {
  return (
    <Sentry.Profiler name="OrderList">
      <OrderList />
    </Sentry.Profiler>
  );
}
```

### 7.3 Custom Transactions

```typescript
// Track important user flows
async function checkoutFlow(cart: Cart) {
  const transaction = Sentry.startTransaction({
    name: 'checkout',
    op: 'checkout.complete',
  });

  Sentry.getCurrentHub().configureScope((scope) => {
    scope.setSpan(transaction);
  });

  try {
    // Step 1: Validate cart
    const validateSpan = transaction.startChild({ op: 'validate', description: 'Validate cart' });
    await validateCart(cart);
    validateSpan.finish();

    // Step 2: Process payment
    const paymentSpan = transaction.startChild({ op: 'payment', description: 'Process payment' });
    const paymentResult = await processPayment(cart);
    paymentSpan.finish();

    // Step 3: Create order
    const orderSpan = transaction.startChild({ op: 'api', description: 'Create order' });
    const order = await api.post('/orders', { cart_id: cart.id, payment_id: paymentResult.id });
    orderSpan.finish();

    transaction.setStatus('ok');
    return order;
  } catch (error) {
    transaction.setStatus('internal_error');
    Sentry.captureException(error);
    throw error;
  } finally {
    transaction.finish();
  }
}
```

---

## 8. Custom Error Boundaries

### 8.1 Global Error Fallback

```tsx
// src/shared/components/ErrorFallback.tsx
import * as Sentry from '@sentry/react';

interface ErrorFallbackProps {
  error: Error;
  componentStack: string | null;
  eventId: string | null;
  resetError: () => void;
}

export function ErrorFallback({
  error,
  componentStack,
  eventId,
  resetError,
}: ErrorFallbackProps) {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50 px-4">
      <div className="max-w-md w-full text-center">
        <div className="text-6xl mb-4">😵</div>
        <h1 className="text-2xl font-bold text-gray-900 mb-2">
          Something went wrong
        </h1>
        <p className="text-gray-600 mb-6">
          We've been notified and are looking into it. Please try again.
        </p>

        <div className="space-y-3">
          <button
            onClick={resetError}
            className="w-full bg-blue-600 text-white rounded-lg px-6 py-3 font-medium hover:bg-blue-700"
          >
            Try Again
          </button>

          <button
            onClick={() => window.location.reload()}
            className="w-full bg-gray-200 text-gray-800 rounded-lg px-6 py-3 font-medium hover:bg-gray-300"
          >
            Reload Page
          </button>

          {eventId && (
            <button
              onClick={() => Sentry.showReportDialog({ eventId })}
              className="w-full text-blue-600 underline text-sm"
            >
              Report this issue
            </button>
          )}
        </div>

        {import.meta.env.DEV && (
          <details className="mt-6 text-left">
            <summary className="text-sm text-gray-500 cursor-pointer">
              Error Details (dev only)
            </summary>
            <pre className="mt-2 p-4 bg-red-50 rounded text-xs text-red-800 overflow-auto">
              {error.message}
              {componentStack}
            </pre>
          </details>
        )}
      </div>
    </div>
  );
}
```

### 8.2 Feature-Level Error Boundaries

Wrap individual features so one broken component doesn't crash the whole app:

```tsx
// src/shared/components/FeatureErrorBoundary.tsx
import * as Sentry from '@sentry/react';

interface FeatureErrorBoundaryProps {
  feature: string;
  children: React.ReactNode;
  fallback?: React.ReactNode;
}

export function FeatureErrorBoundary({
  feature,
  children,
  fallback,
}: FeatureErrorBoundaryProps) {
  return (
    <Sentry.ErrorBoundary
      beforeCapture={(scope) => {
        scope.setTag('feature', feature);
      }}
      fallback={
        fallback || (
          <div className="p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
            <p className="text-yellow-800">
              This section encountered an error and couldn't load.
              <button
                onClick={() => window.location.reload()}
                className="ml-2 underline"
              >
                Reload
              </button>
            </p>
          </div>
        )
      }
    >
      {children}
    </Sentry.ErrorBoundary>
  );
}
```

Usage:

```tsx
// src/pages/Dashboard.tsx
import { FeatureErrorBoundary } from '@/shared/components/FeatureErrorBoundary';

export function Dashboard() {
  return (
    <div className="grid grid-cols-2 gap-4">
      <FeatureErrorBoundary feature="order-list">
        <RecentOrders />
      </FeatureErrorBoundary>

      <FeatureErrorBoundary feature="analytics-chart">
        <SalesChart />
      </FeatureErrorBoundary>

      <FeatureErrorBoundary feature="notifications">
        <NotificationPanel />
      </FeatureErrorBoundary>
    </div>
  );
}
```

---

## 9. Alert Rules and Notifications

### 9.1 Default Alert Rules

Sentry creates default alerts, but customize them:

1. Go to **Alerts** → **Create Alert Rule**
2. Set up these recommended rules:

| Alert | Condition | Action | Frequency |
|-------|-----------|--------|-----------|
| New error | First seen event | Slack + Email | Immediate |
| Error spike | >10 events in 1 hour | Slack | Every 1 hour |
| High error rate | >5% of requests fail | PagerDuty/Slack | Every 30 min |
| Slow API | P95 latency > 2s | Email | Every 4 hours |
| New user-facing error | Frontend, first seen | Slack | Immediate |

### 9.2 Slack Integration

1. Go to **Settings** → **Integrations** → **Slack**
2. Connect your Slack workspace
3. Configure which channels receive which alerts:
   - `#alerts-critical` → Payment errors, auth failures
   - `#alerts-errors` → All new errors
   - `#alerts-performance` → Slow transactions

### 9.3 Custom Alert Example

```
Alert: Payment Processing Failure
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Conditions:
  - Event tagged with: action = "process_payment"
  - Error level: error or fatal
  - First time seen OR occurs 3+ times in 10 minutes

Actions:
  - Send Slack notification to #alerts-critical
  - Send email to on-call@shimizu-technology.com

Rate limit: Every 10 minutes (don't spam)
```

---

## 10. Environment-Specific Configuration

### 10.1 Environment Variables

```bash
# .env.production (Rails)
SENTRY_DSN=https://abc123@o123456.ingest.sentry.io/1234567
RAILS_ENV=production

# .env.staging (Rails)
SENTRY_DSN=https://abc123@o123456.ingest.sentry.io/1234567
RAILS_ENV=staging

# .env (React — Netlify sets these)
VITE_SENTRY_DSN=https://def456@o123456.ingest.sentry.io/7654321
```

### 10.2 Different Sampling per Environment

```ruby
# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']
  config.environment = Rails.env

  # Sample rates per environment
  config.traces_sample_rate = case Rails.env
                              when 'production' then 0.1   # 10% — save quota
                              when 'staging'    then 0.5   # 50% — more visibility
                              else 1.0                      # 100% — full visibility
                              end

  # Only send errors in specific environments
  config.enabled_environments = %w[production staging]
end
```

```typescript
// React — different config per environment
Sentry.init({
  dsn: import.meta.env.VITE_SENTRY_DSN,
  environment: import.meta.env.MODE,
  enabled: import.meta.env.PROD, // Only in production builds

  tracesSampleRate: import.meta.env.MODE === 'production' ? 0.1 : 1.0,
  replaysSessionSampleRate: import.meta.env.MODE === 'production' ? 0.1 : 0,
  replaysOnErrorSampleRate: 1.0,
});
```

### 10.3 Development: Optional Local Sentry

```ruby
# config/environments/development.rb
# Uncomment to test Sentry locally:
# Sentry.init do |config|
#   config.dsn = ENV['SENTRY_DSN']
#   config.environment = 'development'
#   config.traces_sample_rate = 1.0
# end
```

---

## 11. Advanced Patterns

### 11.1 Background Job Error Context

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    Sentry.with_scope do |scope|
      scope.set_tags(
        job_class: job.class.name,
        queue: job.queue_name,
        job_id: job.job_id
      )
      scope.set_extras(
        arguments: job.arguments,
        executions: job.executions
      )

      block.call
    end
  end
end
```

### 11.2 API Error Response Integration

```ruby
# app/controllers/concerns/error_handler.rb
module ErrorHandler
  extend ActiveSupport::Concern

  included do
    rescue_from StandardError, with: :handle_internal_error
    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found
    rescue_from ActiveRecord::RecordInvalid, with: :handle_validation_error
    rescue_from ActionController::ParameterMissing, with: :handle_bad_request
  end

  private

  def handle_internal_error(error)
    # Sentry captures this automatically, but we can add context
    Sentry.capture_exception(error, extra: {
      params: request.filtered_parameters,
      path: request.path,
      method: request.method
    })

    render json: {
      error: 'Internal server error',
      reference: Sentry.last_event_id  # Give user a reference ID
    }, status: :internal_server_error
  end

  def handle_not_found(error)
    render json: { error: 'Not found' }, status: :not_found
  end

  def handle_validation_error(error)
    render json: {
      error: 'Validation failed',
      details: error.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  def handle_bad_request(error)
    render json: { error: error.message }, status: :bad_request
  end
end
```

### 11.3 React: API Error Interceptor

```typescript
// src/shared/services/api.ts
import axios from 'axios';
import * as Sentry from '@sentry/react';

const api = axios.create({
  baseURL: `${import.meta.env.VITE_API_URL}/api/v1`,
});

// Response interceptor — capture API errors
api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response) {
      // Server responded with error status
      const { status, data } = error.response;

      if (status >= 500) {
        Sentry.captureException(error, {
          tags: {
            api_status: status,
            api_url: error.config?.url,
          },
          extra: {
            response_data: data,
            request_params: error.config?.params,
          },
        });
      }

      // Add Sentry event ID to error for user reference
      if (data?.reference) {
        error.sentryEventId = data.reference;
      }
    } else if (error.request) {
      // Network error
      Sentry.captureException(error, {
        tags: { error_type: 'network' },
      });
    }

    return Promise.reject(error);
  }
);

export default api;
```

### 11.4 Fingerprinting (Group Similar Errors)

```ruby
# config/initializers/sentry.rb
Sentry.init do |config|
  config.before_send = lambda { |event, hint|
    exception = hint[:exception]

    # Group all Stripe errors by error code
    if exception.is_a?(Stripe::StripeError)
      event.fingerprint = ['stripe', exception.code]
    end

    # Group all timeout errors together
    if exception.is_a?(Net::ReadTimeout)
      event.fingerprint = ['timeout', event.request&.url]
    end

    event
  }
end
```

---

## 12. Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Errors not appearing in Sentry | DSN not set or wrong | Check `ENV['SENTRY_DSN']` in production |
| React source maps not working | Not uploaded or wrong release | Check build logs for upload confirmation |
| Too many errors (quota hit) | Not filtering noise | Add `excluded_exceptions` and `beforeSend` filters |
| User context missing | Not setting user | Add `set_sentry_user` in controller/provider |
| Duplicate errors | Missing fingerprinting | Configure fingerprint rules |
| Performance data missing | `traces_sample_rate` is 0 | Set to at least 0.1 |

### Verify Sentry is Working

```ruby
# Rails console — trigger a test error
Sentry.capture_message("Test from Rails console", level: :info)
```

```typescript
// React — trigger a test error (dev console)
import * as Sentry from '@sentry/react';
Sentry.captureMessage('Test from React frontend');
```

```ruby
# Or raise a real error
raise "Test Sentry error — please ignore" if ENV['TEST_SENTRY']
```

### Cost Management

Sentry's free tier includes 5K errors/month. To stay within limits:

1. **Filter noise** in `beforeSend` (ResizeObserver, extensions, bots)
2. **Exclude 404s** from Rails (`ActionController::RoutingError`)
3. **Sample performance traces** (10% is usually enough)
4. **Rate limit** alert rules to avoid notification fatigue
5. **Set up spike protection** in Sentry settings

### Sentry vs Alternatives

| Feature | Sentry | Bugsnag | Rollbar | Honeybadger |
|---------|--------|---------|---------|-------------|
| Free tier | 5K errors/mo | 7.5K errors/mo | 5K errors/mo | None |
| Rails support | ✅ Excellent | ✅ Good | ✅ Good | ✅ Excellent |
| React support | ✅ Excellent | ✅ Good | ✅ Good | ⚠️ Basic |
| Performance monitoring | ✅ Built-in | ❌ No | ❌ No | ❌ No |
| Session replay | ✅ Built-in | ❌ No | ❌ No | ❌ No |
| Source maps | ✅ Automatic | ✅ Automatic | ✅ Automatic | ⚠️ Manual |
| Self-hosted option | ✅ Yes | ❌ No | ❌ No | ❌ No |

> **The Shimizu Way:** Sentry wins for Rails + React stacks. The free tier is generous, the React SDK is best-in-class, and performance monitoring is included. No need to evaluate alternatives unless you have specific requirements.
