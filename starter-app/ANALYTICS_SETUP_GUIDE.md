# Analytics Setup Guide

A guide for setting up analytics and tracking on client web applications.

---

## Table of Contents
1. [PostHog (Recommended)](#1-posthog-recommended)
2. [Google Analytics (Alternative)](#2-google-analytics-alternative)
3. [Event Tracking Best Practices](#3-event-tracking-best-practices)
4. [Privacy & Consent](#4-privacy--consent)

---

## 1. PostHog (Recommended)

PostHog is a privacy-friendly, open-source alternative to Google Analytics with built-in feature flags, session replay, and more.

### Installation

```bash
npm install posthog-js
```

### Environment Variables

Add to `.env` (frontend):
```bash
VITE_PUBLIC_POSTHOG_KEY=phc_xxxxxxxxxxxxx
VITE_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
```

### React Setup

Create `src/providers/PostHogProvider.tsx`:

```tsx
import { useEffect } from 'react'
import posthog from 'posthog-js'
import { PostHogProvider as PHProvider, usePostHog } from 'posthog-js/react'
import { useLocation } from 'react-router-dom'

const POSTHOG_KEY = import.meta.env.VITE_PUBLIC_POSTHOG_KEY
const POSTHOG_HOST = import.meta.env.VITE_PUBLIC_POSTHOG_HOST || 'https://us.i.posthog.com'
const isPostHogEnabled = Boolean(POSTHOG_KEY && POSTHOG_KEY !== 'YOUR_POSTHOG_KEY')

// Initialize PostHog
if (isPostHogEnabled && typeof window !== 'undefined') {
  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    defaults: '2025-11-30',
    capture_pageview: false, // Manual capture for SPA
    capture_pageleave: true,
    autocapture: true,
  })
}

// Page view tracker for SPA
export function PostHogPageView() {
  const location = useLocation()
  const posthogClient = usePostHog()

  useEffect(() => {
    if (posthogClient && isPostHogEnabled) {
      posthogClient.capture('$pageview', {
        $current_url: window.location.href,
        $pathname: location.pathname,
      })
    }
  }, [location, posthogClient])

  return null
}

interface PostHogProviderProps {
  children: React.ReactNode
}

export function PostHogProvider({ children }: PostHogProviderProps) {
  if (!isPostHogEnabled) {
    if (import.meta.env.DEV) {
      console.info('PostHog not configured - analytics disabled')
    }
    return <>{children}</>
  }

  return (
    <PHProvider client={posthog}>
      {children}
    </PHProvider>
  )
}

export { usePostHog, isPostHogEnabled }
```

### Integration in App

In `main.tsx`:
```tsx
import { PostHogProvider } from './providers/PostHogProvider'

// Wrap your app
<PostHogProvider>
  <App />
</PostHogProvider>
```

In `App.tsx` (inside BrowserRouter):
```tsx
import { PostHogPageView } from './providers/PostHogProvider'

function App() {
  return (
    <BrowserRouter>
      <PostHogPageView />
      <Routes>
        {/* ... routes */}
      </Routes>
    </BrowserRouter>
  )
}
```

### Tracking Custom Events

```tsx
import { usePostHog } from '../providers/PostHogProvider'

function MyComponent() {
  const posthog = usePostHog()
  
  const handleSignup = () => {
    posthog?.capture('user_signed_up', {
      plan: 'free',
      source: 'homepage'
    })
  }
  
  return <button onClick={handleSignup}>Sign Up</button>
}
```

### Common Events to Track

| Event Name | When to Track | Properties |
|------------|---------------|------------|
| `user_signed_up` | After signup | plan, source |
| `user_logged_in` | After login | method (email, google, etc) |
| `form_submitted` | Form submission | form_name, success |
| `button_clicked` | Important CTAs | button_name, page |
| `feature_used` | Key features | feature_name |
| `purchase_completed` | After purchase | amount, product |

### Identifying Users

```tsx
// After user logs in
posthog?.identify(userId, {
  email: user.email,
  name: user.name,
  plan: user.plan,
})

// After user logs out
posthog?.reset()
```

### PostHog Dashboard Setup

1. Go to [PostHog](https://posthog.com) and create account
2. Create new project
3. Copy API key from Project Settings
4. Add to environment variables
5. Deploy and verify events are flowing

---

## 2. Google Analytics (Alternative)

If the client specifically needs Google Analytics.

### Setup

1. Go to [Google Analytics](https://analytics.google.com)
2. Create property
3. Get Measurement ID (G-XXXXXXXXXX)

### Installation (gtag.js)

Add to `index.html` before closing `</head>`:

```html
<!-- Google Analytics -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

### SPA Page View Tracking

For React Router SPAs, track page views on navigation:

```tsx
import { useEffect } from 'react'
import { useLocation } from 'react-router-dom'

function useGoogleAnalytics() {
  const location = useLocation()

  useEffect(() => {
    if (typeof window.gtag === 'function') {
      window.gtag('config', 'G-XXXXXXXXXX', {
        page_path: location.pathname + location.search,
      })
    }
  }, [location])
}
```

### Custom Events

```tsx
// Track an event
window.gtag('event', 'sign_up', {
  method: 'email'
})

// Track a purchase
window.gtag('event', 'purchase', {
  transaction_id: 'T12345',
  value: 99.99,
  currency: 'USD'
})
```

---

## 3. Event Tracking Best Practices

### Naming Conventions

Use consistent `object_action` format:
- `user_signed_up` (not `signUp` or `user-signed-up`)
- `form_submitted`
- `button_clicked`
- `page_viewed`

### What to Track

**Always Track:**
- Page views
- Sign ups / registrations
- Logins
- Key conversions (purchases, form submissions)
- Errors

**Consider Tracking:**
- Feature usage
- Search queries
- Button clicks on CTAs
- Time on page
- Scroll depth

**Don't Track:**
- Every click (use autocapture selectively)
- Sensitive/PII data
- Internal admin actions

### Properties to Include

```tsx
// Good: Include context
posthog?.capture('form_submitted', {
  form_name: 'contact',
  page: '/contact',
  has_attachment: true,
})

// Bad: No context
posthog?.capture('form_submitted')
```

---

## 4. Privacy & Consent

### GDPR/CCPA Considerations

If you have EU or California users, you may need consent before tracking.

### Cookie Consent Banner

Options:
- [Cookiebot](https://www.cookiebot.com/)
- [OneTrust](https://www.onetrust.com/)
- Build custom banner

### PostHog Privacy Options

```tsx
posthog.init(POSTHOG_KEY, {
  api_host: POSTHOG_HOST,
  
  // Cookieless mode - no cookies, uses memory
  persistence: 'memory',
  
  // Or opt-out by default, opt-in after consent
  opt_out_capturing_by_default: true,
})

// After user consents
posthog.opt_in_capturing()

// If user declines
posthog.opt_out_capturing()
```

### Disable in Development

```tsx
if (isPostHogEnabled && typeof window !== 'undefined') {
  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    // Disable in development
    loaded: (posthog) => {
      if (import.meta.env.DEV) {
        posthog.opt_out_capturing()
      }
    },
  })
}
```

---

## Quick Checklist

```
□ Analytics provider chosen (PostHog recommended)
□ Package installed
□ Environment variables set (dev and production)
□ Provider component created
□ App wrapped with provider
□ Page view tracking for SPA
□ Key events identified and tracked
□ User identification on login
□ Production environment verified
□ Privacy/consent handled if needed
```

---

## Comparison: PostHog vs Google Analytics

| Feature | PostHog | Google Analytics |
|---------|---------|------------------|
| Privacy | Self-host option, EU hosting | Google servers |
| Free tier | 1M events/month | Unlimited (with sampling) |
| Session replay | ✅ Built-in | ❌ Need separate tool |
| Feature flags | ✅ Built-in | ❌ Need separate tool |
| Heatmaps | ✅ Built-in | ❌ Need separate tool |
| A/B testing | ✅ Built-in | ✅ Via Optimize |
| Learning curve | Moderate | Easy |
| Real-time | ✅ | ✅ |

**Recommendation**: Use PostHog for most projects. Use GA if client specifically requests it or needs integration with Google Ads.

---

*Last updated: January 2026*
