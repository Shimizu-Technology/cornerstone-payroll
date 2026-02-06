# PWA Setup Guide

A guide for making React/Vite apps installable as Progressive Web Apps.

---

## Table of Contents
1. [What is a PWA?](#1-what-is-a-pwa)
2. [Quick Setup (5 minutes)](#2-quick-setup-5-minutes)
3. [Manifest.json Deep Dive](#3-manifestjson-deep-dive)
4. [iOS-Specific Setup](#4-ios-specific-setup)
5. [Icons & Images](#5-icons--images)
6. [Testing Your PWA](#6-testing-your-pwa)
7. [Advanced: Service Worker](#7-advanced-service-worker)
8. [Common Issues](#8-common-issues)

---

## 1. What is a PWA?

A Progressive Web App is a website that can be "installed" on a device like a native app.

### Benefits
- **Installable**: Add to home screen on mobile/desktop
- **Fullscreen**: Runs without browser UI (address bar)
- **Offline capable**: With service worker (optional)
- **App-like**: Feels native, has its own icon

### What You Get Without Much Effort

| Feature | Effort | Value |
|---------|--------|-------|
| Install prompt | Low (manifest.json) | High |
| Home screen icon | Low (manifest.json) | High |
| Fullscreen mode | Low (manifest.json) | Medium |
| Theme color (status bar) | Low (meta tag) | Medium |
| Splash screen | Low (manifest.json) | Medium |
| Offline support | High (service worker) | Varies |

### Minimum Requirements for Installability

1. Valid `manifest.json` linked in HTML
2. HTTPS (or localhost for dev)
3. At least one icon (192x192 minimum)
4. `display` set to `standalone`, `fullscreen`, or `minimal-ui`

---

## 2. Quick Setup (5 minutes)

### Step 1: Create manifest.json

Create `public/manifest.json`:

```json
{
  "name": "Your App Name",
  "short_name": "AppName",
  "description": "Brief description of your app",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#000000",
  "orientation": "portrait-primary",
  "scope": "/",
  "icons": [
    {
      "src": "/logo.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/logo.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any"
    }
  ]
}
```

### Step 2: Add to index.html

Add these tags inside `<head>`:

```html
<!-- PWA Manifest -->
<link rel="manifest" href="/manifest.json" />

<!-- Theme Color (browser UI, Android status bar) -->
<meta name="theme-color" content="#000000" />

<!-- iOS PWA Support -->
<meta name="apple-mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
<meta name="apple-mobile-web-app-title" content="AppName" />
<link rel="apple-touch-icon" href="/logo.png" />

<!-- Windows Tile -->
<meta name="msapplication-TileColor" content="#000000" />
```

### Step 3: Add Your Icon

Place your logo in `public/`:
```
public/
├── logo.png (or logo.jpeg)
├── manifest.json
└── ...
```

### Step 4: Deploy & Test

That's it! Deploy your app and it will be installable.

---

## 3. Manifest.json Deep Dive

### Full Example (What We Use)

```json
{
  "name": "Cornerstone Accounting & Business Services",
  "short_name": "Cornerstone",
  "description": "Professional tax preparation, bookkeeping, and business services.",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#f5f3ef",
  "theme_color": "#2d2a26",
  "orientation": "portrait-primary",
  "scope": "/",
  "icons": [
    {
      "src": "/logo.jpeg",
      "sizes": "512x512",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "192x192",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "180x180",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "152x152",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "144x144",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "120x120",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "96x96",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "72x72",
      "type": "image/jpeg",
      "purpose": "any"
    },
    {
      "src": "/logo.jpeg",
      "sizes": "48x48",
      "type": "image/jpeg",
      "purpose": "any"
    }
  ],
  "categories": ["business", "finance"],
  "lang": "en-US"
}
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Full app name (shown on splash screen) |
| `short_name` | Yes | Short name (shown under icon, max ~12 chars) |
| `start_url` | Yes | URL when app opens (usually `/`) |
| `display` | Yes | How app displays (see below) |
| `icons` | Yes | At least 192x192 and 512x512 |
| `background_color` | Recommended | Splash screen background |
| `theme_color` | Recommended | Status bar color on Android |
| `description` | Optional | App description |
| `orientation` | Optional | Lock orientation |
| `scope` | Optional | URL scope for the app |
| `categories` | Optional | App store categories |
| `lang` | Optional | Language code |

### Display Modes

| Mode | Browser UI | Status Bar | Use Case |
|------|-----------|------------|----------|
| `standalone` | Hidden | Visible | **Most common** - like a native app |
| `fullscreen` | Hidden | Hidden | Games, immersive experiences |
| `minimal-ui` | Minimal | Visible | When back button is needed |
| `browser` | Full | Visible | Regular browser (defeats purpose) |

### Orientation Options

| Value | Description |
|-------|-------------|
| `portrait-primary` | Portrait only, natural orientation |
| `portrait` | Portrait, either direction |
| `landscape-primary` | Landscape only |
| `landscape` | Landscape, either direction |
| `any` | Any orientation (default) |

---

## 4. iOS-Specific Setup

iOS Safari doesn't fully support `manifest.json`, so you need meta tags.

### Required Meta Tags

```html
<!-- Makes it installable to home screen -->
<meta name="apple-mobile-web-app-capable" content="yes" />

<!-- Status bar appearance -->
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />

<!-- App name shown under icon -->
<meta name="apple-mobile-web-app-title" content="AppName" />

<!-- Home screen icon -->
<link rel="apple-touch-icon" href="/logo.png" />
```

### Status Bar Styles

| Value | Appearance |
|-------|------------|
| `default` | White status bar with black text |
| `black` | Black status bar with white text |
| `black-translucent` | Transparent, content extends under status bar |

**Tip**: `black-translucent` looks best for most apps. Content extends under the status bar, so add padding if needed.

### Multiple Icon Sizes for iOS

For best results on all iOS devices:

```html
<link rel="apple-touch-icon" sizes="180x180" href="/icons/apple-touch-icon-180x180.png" />
<link rel="apple-touch-icon" sizes="152x152" href="/icons/apple-touch-icon-152x152.png" />
<link rel="apple-touch-icon" sizes="144x144" href="/icons/apple-touch-icon-144x144.png" />
<link rel="apple-touch-icon" sizes="120x120" href="/icons/apple-touch-icon-120x120.png" />
<link rel="apple-touch-icon" sizes="114x114" href="/icons/apple-touch-icon-114x114.png" />
<link rel="apple-touch-icon" sizes="76x76" href="/icons/apple-touch-icon-76x76.png" />
<link rel="apple-touch-icon" sizes="72x72" href="/icons/apple-touch-icon-72x72.png" />
<link rel="apple-touch-icon" sizes="60x60" href="/icons/apple-touch-icon-60x60.png" />
<link rel="apple-touch-icon" sizes="57x57" href="/icons/apple-touch-icon-57x57.png" />
```

**Practical approach**: Just use one high-resolution icon and let iOS resize it:

```html
<link rel="apple-touch-icon" href="/logo.png" />
```

### iOS Splash Screens (Optional)

For custom splash screens on iOS, you need specific sizes for each device. This is tedious, so most skip it. If you want them, use a generator like [pwa-asset-generator](https://github.com/nickvision/pwa-asset-generator).

---

## 5. Icons & Images

### Minimum Icons Needed

| Size | Required For | Priority |
|------|--------------|----------|
| 512x512 | Android install, splash | **Required** |
| 192x192 | Android home screen | **Required** |
| 180x180 | iOS home screen | Recommended |
| 32x32 | Browser tab favicon | Nice to have |
| 16x16 | Browser tab favicon | Nice to have |

### Single Image Approach (What We Use)

If you have one good logo, just reference it with multiple sizes:

```json
{
  "icons": [
    { "src": "/logo.jpeg", "sizes": "512x512", "type": "image/jpeg", "purpose": "any" },
    { "src": "/logo.jpeg", "sizes": "192x192", "type": "image/jpeg", "purpose": "any" },
    { "src": "/logo.jpeg", "sizes": "180x180", "type": "image/jpeg", "purpose": "any" }
  ]
}
```

The browser will resize as needed. Quality is fine for most apps.

### Proper Multi-Size Approach

For best quality, create actual resized versions:

```
public/
├── icons/
│   ├── icon-512x512.png
│   ├── icon-192x192.png
│   ├── icon-180x180.png
│   ├── icon-144x144.png
│   └── icon-96x96.png
├── manifest.json
└── ...
```

### Icon Purpose Field

| Value | Description |
|-------|-------------|
| `any` | Standard icon usage |
| `maskable` | Safe zone for adaptive icons (Android) |
| `monochrome` | Single color (for themed icons) |

**Tip**: Use `any` unless you've specifically designed a maskable icon with safe zones.

### Generating Icons

Tools to generate all sizes from one image:

1. **[RealFaviconGenerator](https://realfavicongenerator.net/)** - Best, generates everything
2. **[PWA Asset Generator](https://github.com/nickvision/pwa-asset-generator)** - CLI tool
3. **[Maskable.app](https://maskable.app/)** - Test/create maskable icons

---

## 6. Testing Your PWA

### Chrome DevTools (Best)

1. Open your app in Chrome
2. Open DevTools (F12)
3. Go to **Application** tab
4. Check **Manifest** section - should show your manifest
5. Check for warnings/errors

### Lighthouse Audit

1. Open DevTools → **Lighthouse** tab
2. Check "Progressive Web App"
3. Run audit
4. Review PWA-specific results

### Install Testing

**Desktop Chrome:**
- Look for install icon in address bar
- Or: Menu (⋮) → "Install [App Name]"

**Mobile Android:**
- Chrome shows "Add to Home Screen" banner automatically
- Or: Menu → "Add to Home Screen"

**Mobile iOS:**
- Safari → Share button → "Add to Home Screen"
- Note: Only works in Safari, not other browsers

### Quick Checklist

```
□ manifest.json loads (check DevTools → Application)
□ All required fields present (name, short_name, icons, display, start_url)
□ At least 192x192 icon present
□ theme-color meta tag present
□ Site served over HTTPS (or localhost)
□ No manifest errors in DevTools
□ Can install to home screen
```

---

## 7. Advanced: Service Worker

A service worker enables offline functionality. Skip this if you don't need offline support.

### Simple Offline Page

Create `public/sw.js`:

```javascript
const CACHE_NAME = 'app-v1';
const OFFLINE_URL = '/offline.html';

// Install: cache offline page
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.add(OFFLINE_URL);
    })
  );
  self.skipWaiting();
});

// Activate: clean old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

// Fetch: serve cached content when offline
self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch(() => {
        return caches.match(OFFLINE_URL);
      })
    );
  }
});
```

Create `public/offline.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <title>Offline</title>
  <style>
    body { font-family: sans-serif; text-align: center; padding: 50px; }
  </style>
</head>
<body>
  <h1>You're Offline</h1>
  <p>Please check your internet connection.</p>
</body>
</html>
```

Register in your app (e.g., `main.tsx`):

```typescript
// Register service worker
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js')
      .then(() => console.log('SW registered'))
      .catch((err) => console.log('SW registration failed:', err));
  });
}
```

### Vite PWA Plugin (Easier)

For more robust offline support, use [vite-plugin-pwa](https://vite-pwa-org.netlify.app/):

```bash
npm install vite-plugin-pwa -D
```

```typescript
// vite.config.ts
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'Your App Name',
        short_name: 'App',
        // ... rest of manifest
      }
    })
  ]
})
```

This auto-generates the service worker and handles caching.

---

## 8. Common Issues

### Install prompt not showing

**Causes:**
1. Not on HTTPS (except localhost)
2. Missing required manifest fields
3. Already installed
4. Browser cached old manifest

**Fix:**
1. Deploy to HTTPS
2. Check DevTools → Application → Manifest for errors
3. Uninstall the app and try again
4. Hard refresh (Ctrl+Shift+R)

### Icons not showing on home screen

**Causes:**
1. Wrong icon path in manifest
2. Icon not in `public/` folder
3. Wrong MIME type

**Fix:**
1. Verify paths are absolute (`/logo.png` not `logo.png`)
2. Ensure icon is in `public/` and deployed
3. Check `type` field matches actual image format

### iOS not respecting manifest

**Cause:** iOS Safari has limited manifest support

**Fix:** Use meta tags in addition to manifest:
```html
<meta name="apple-mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-title" content="AppName" />
<link rel="apple-touch-icon" href="/logo.png" />
```

### Theme color not applying

**Causes:**
1. Missing `theme-color` meta tag
2. iOS doesn't support `theme-color` the same way

**Fix:**
```html
<meta name="theme-color" content="#000000" />
<!-- For iOS status bar: -->
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
```

### App opens in browser instead of standalone

**Causes:**
1. `display` not set to `standalone`
2. Opened via bookmark, not installed app

**Fix:**
1. Set `"display": "standalone"` in manifest
2. Make sure user installed the app, not just bookmarked

### Manifest not loading

**Causes:**
1. Wrong path to manifest
2. Wrong MIME type from server
3. Syntax error in JSON

**Fix:**
1. Use absolute path: `href="/manifest.json"`
2. Check manifest loads: open `https://yoursite.com/manifest.json` in browser
3. Validate JSON: paste into [jsonlint.com](https://jsonlint.com/)

---

## Complete index.html Example

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    
    <!-- Primary Meta Tags -->
    <title>Your App Name</title>
    <meta name="description" content="Your app description" />
    
    <!-- Favicon -->
    <link rel="icon" type="image/png" href="/logo.png" />
    
    <!-- PWA Manifest -->
    <link rel="manifest" href="/manifest.json" />
    
    <!-- Theme Color -->
    <meta name="theme-color" content="#000000" />
    <meta name="msapplication-TileColor" content="#000000" />
    
    <!-- iOS PWA -->
    <meta name="apple-mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
    <meta name="apple-mobile-web-app-title" content="AppName" />
    <link rel="apple-touch-icon" href="/logo.png" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

---

## Quick Checklist

```
□ public/manifest.json created
□ manifest.json has: name, short_name, start_url, display, icons
□ At least 192x192 and 512x512 icons
□ <link rel="manifest" href="/manifest.json" /> in index.html
□ <meta name="theme-color" content="#xxx" /> in index.html
□ iOS meta tags added (apple-mobile-web-app-*)
□ Icon referenced in <link rel="apple-touch-icon" />
□ Deployed to HTTPS
□ Tested install on mobile device
```

---

*Last updated: January 2026*
