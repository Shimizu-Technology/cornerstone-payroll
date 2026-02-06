# Mobile App Deployment Guide (iOS + Android)

A guide for deploying React Native / Expo apps to the Apple App Store and Google Play Store using EAS Build.

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [EAS Build Setup](#3-eas-build-setup)
4. [iOS App Store Deployment](#4-ios-app-store-deployment)
5. [Google Play Store Deployment](#5-google-play-store-deployment)
6. [OAuth Configuration (Clerk)](#6-oauth-configuration-clerk)
7. [Deep Linking Setup](#7-deep-linking-setup)
8. [Environment Variables](#8-environment-variables)
9. [Version Management](#9-version-management)
10. [Android Debugging with ADB](#10-android-debugging-with-adb)
11. [Release Process Checklist](#11-release-process-checklist)
12. [Common Issues & Solutions](#12-common-issues--solutions)
13. [Cost Overview](#13-cost-overview)

---

## 1. Architecture Overview

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Local Dev     │────▶│    EAS Build    │────▶│   App Stores    │
│   (Expo)        │     │   (Cloud)       │     │  (iOS/Android)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
   expo start              eas build              TestFlight
   (development)           (production)           Google Play
```

### Build Flow

| Stage | Tool | Output |
|-------|------|--------|
| Development | `expo start` | Local dev client |
| Preview | `eas build --profile preview` | Internal testing build |
| Production | `eas build --profile production` | Store-ready build |
| Submission | `eas submit` | Upload to App Store / Play Store |

### Why EAS Build?

| Feature | EAS Build | Local Build |
|---------|-----------|-------------|
| No macOS required | ✅ | ❌ (iOS needs Mac) |
| Automatic signing | ✅ | Manual setup |
| CI/CD ready | ✅ | Custom setup |
| Build caching | ✅ | ❌ |
| Cost | Free tier available | Free but complex |

---

## 2. Prerequisites

### Required Accounts

- [ ] **Expo account** ([expo.dev](https://expo.dev)) - Free
- [ ] **Apple Developer account** ([developer.apple.com](https://developer.apple.com)) - $99/year
- [ ] **Google Play Developer account** ([play.google.com/console](https://play.google.com/console)) - $25 one-time

### Required Tools

```bash
# Install EAS CLI globally
npm install -g eas-cli

# Login to Expo
eas login

# Verify login
eas whoami
```

### Project Requirements

- [ ] `app.json` or `app.config.js` configured
- [ ] Unique bundle identifier (e.g., `com.yourcompany.appname`)
- [ ] App icons in required sizes
- [ ] Splash screen configured

---

## 3. EAS Build Setup

### 3.1 Initialize EAS

```bash
cd your-expo-project
eas build:configure
```

This creates `eas.json` with build profiles.

### 3.2 Configure eas.json

```json
{
  "cli": {
    "version": ">= 5.0.0",
    "appVersionSource": "remote"
  },
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal",
      "ios": {
        "simulator": true
      }
    },
    "preview": {
      "distribution": "internal",
      "ios": {
        "simulator": false
      }
    },
    "production": {
      "autoIncrement": true,
      "env": {
        "SENTRY_ALLOW_FAILURE": "true"
      }
    }
  },
  "submit": {
    "production": {
      "ios": {
        "appleId": "your@email.com",
        "ascAppId": "1234567890"
      },
      "android": {
        "serviceAccountKeyPath": "./google-play-key.json",
        "track": "internal"
      }
    }
  }
}
```

### 3.3 Configure app.json

```json
{
  "expo": {
    "name": "Your App Name",
    "slug": "your-app-slug",
    "version": "1.0.0",
    "orientation": "portrait",
    "icon": "./assets/images/icon.png",
    "scheme": "yourapp",
    "userInterfaceStyle": "automatic",
    "splash": {
      "image": "./assets/images/splash-icon.png",
      "resizeMode": "contain",
      "backgroundColor": "#ffffff"
    },
    "ios": {
      "supportsTablet": true,
      "bundleIdentifier": "com.yourcompany.appname",
      "buildNumber": "1",
      "infoPlist": {
        "ITSAppUsesNonExemptEncryption": false
      }
    },
    "android": {
      "adaptiveIcon": {
        "foregroundImage": "./assets/images/adaptive-icon.png",
        "backgroundColor": "#ffffff"
      },
      "package": "com.yourcompany.appname",
      "intentFilters": [
        {
          "action": "VIEW",
          "category": ["BROWSABLE", "DEFAULT"],
          "data": [
            {
              "scheme": "yourapp"
            }
          ]
        }
      ]
    },
    "extra": {
      "eas": {
        "projectId": "your-project-id"
      }
    },
    "owner": "your-expo-username"
  }
}
```

---

## 4. iOS App Store Deployment

### 4.1 Apple Developer Setup

1. Go to [developer.apple.com](https://developer.apple.com)
2. Enroll in Apple Developer Program ($99/year)
3. Wait for approval (usually 24-48 hours)

### 4.2 App Store Connect Setup

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. Click **My Apps** → **+** → **New App**
3. Fill in:
   - **Platform**: iOS
   - **Name**: Your App Name
   - **Primary Language**: English (US)
   - **Bundle ID**: Select from dropdown (created by EAS)
   - **SKU**: Unique identifier (e.g., `yourapp-ios-v1`)
   - **User Access**: Full Access

### 4.3 Build for iOS

```bash
# Production build
eas build --platform ios --profile production

# This will:
# 1. Prompt to create certificates/profiles if needed
# 2. Upload to EAS Build servers
# 3. Return a link when complete
```

### 4.4 Submit to App Store

```bash
# Submit the latest build
eas submit --platform ios --latest

# Or submit a specific build
eas submit --platform ios --id BUILD_ID
```

### 4.5 App Store Connect Configuration

#### Required Information

| Field | Example | Notes |
|-------|---------|-------|
| App Name | Your App | Max 30 characters |
| Subtitle | Short tagline | Max 30 characters |
| Keywords | keyword1, keyword2 | Comma-separated, 100 chars max |
| Description | Full description | Up to 4000 characters |
| What's New | Release notes | Required for updates |
| Support URL | https://yoursite.com/support | Required |
| Privacy Policy | https://yoursite.com/privacy | Required |

#### Screenshots Required

| Device | Size | Count |
|--------|------|-------|
| iPhone 6.7" | 1290 x 2796 | 1-10 |
| iPhone 6.5" | 1242 x 2688 | 1-10 |
| iPhone 5.5" | 1242 x 2208 | 1-10 |
| iPad Pro 12.9" | 2048 x 2732 | 1-10 (if supporting iPad) |

### 4.6 TestFlight Setup

1. In App Store Connect, go to **TestFlight**
2. Build appears after processing (5-30 minutes)
3. Add **Internal Testers** (up to 100, instant access)
4. Add **External Testers** (up to 10,000, requires review)

### 4.7 Submit for Review

1. Go to **App Store** tab
2. Select your build under **Build**
3. Fill in **Version Information**
4. Click **Add for Review**
5. Wait for review (typically 24-48 hours)

### 4.8 Demo Account for App Review

Apple requires a working demo account to review your app. If your app uses authentication (like Clerk), you must provide credentials that work without any additional verification steps.

#### Setting Up the Demo Account

1. **Create a dedicated test account** in your app:
   - Email: `applereviewer@test.com` (or similar)
   - Password: A simple, memorable password (e.g., `AppleReview2025!`)

2. **Disable 2FA/Client Trust for the account** (Critical for Clerk users):
   - Go to [Clerk Dashboard](https://dashboard.clerk.com)
   - Navigate to **Users** → Find your demo account
   - Click on the user → Go to **Settings** tab
   - Enable **"Bypass Client Trust"**
   - This prevents Clerk from requiring a second factor for new devices/clients

3. **Pre-populate with sample data**:
   - Add a few sample recipes to the account
   - This allows reviewers to test all features

4. **Provide credentials in App Store Connect**:
   - Go to your app → **App Information** → **App Review Information**
   - Enter the demo account username and password
   - Add any notes about how to use the app

#### Common Demo Account Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| "Unable to sign in" | Account doesn't exist or wrong credentials | Verify account in Clerk dashboard |
| 2FA/verification required | Client Trust enabled | Enable "Bypass Client Trust" in Clerk |
| Account locked | Too many failed attempts | Reset in Clerk dashboard |
| No content to review | Empty account | Add sample recipes before submission |

#### What's New Text Guidelines

When writing "What's New" text for App Store:
- **Do NOT mention Android** or other platforms
- Focus only on iOS-relevant features
- Keep it concise and user-focused

**Bad example**: "Fixed Android OAuth crash, improved iOS performance"  
**Good example**: "Improved performance and bug fixes"

---

## 5. Google Play Store Deployment

### 5.1 Google Play Console Setup

1. Go to [play.google.com/console](https://play.google.com/console)
2. Pay $25 registration fee
3. Complete account setup and verification

**Important**: Google requires identity verification which can take 1-3 days.

### 5.2 Create App Listing

1. Click **Create app**
2. Fill in:
   - **App name**: Your App Name
   - **Default language**: English (US)
   - **App or game**: App
   - **Free or paid**: Free

### 5.3 Service Account for Automated Uploads

Setting up a service account allows `eas submit --platform android` to work automatically.

#### Step 1: Create Service Account in Google Cloud Console

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a new project (or use existing one)
3. Go to **IAM & Admin** → **Service Accounts**
4. Click **Create Service Account**
   - Name: `play-store-upload` (or similar)
   - ID: auto-generated (e.g., `play-store-upload@yourproject.iam.gserviceaccount.com`)
   - Role: **Service Account User** (basic role is fine)
5. Click **Done** to create the account

#### Step 2: Generate JSON Key

1. Click on the newly created service account
2. Go to **Keys** tab
3. Click **Add Key** → **Create new key**
4. Select **JSON** format
5. Download the file and save as `google-play-key.json` in your project root
6. **Add to `.gitignore`** - never commit this file!

#### Step 3: Enable Google Play Developer API

1. In Google Cloud Console, go to **APIs & Services** → **Library**
2. Search for **Google Play Android Developer API**
3. Click **Enable**

#### Step 4: Invite Service Account to Play Console (Critical!)

This is the step most tutorials miss. The service account needs explicit permissions in Play Console:

1. Go to [Google Play Console](https://play.google.com/console)
2. Click **Users and permissions** in the left sidebar
3. Click **Invite new users**
4. Enter the service account email (e.g., `play-store-upload@yourproject.iam.gserviceaccount.com`)
5. Under **App permissions**, click **Add app**
6. Select your app (e.g., "Håfa Recipes")
7. **Check these permissions under "Releases":**
   - ✅ Release apps to testing tracks
   - ✅ Release to production, exclude devices, and use Play App Signing
   - ✅ Manage testing tracks and edit tester lists
8. Click **Apply** then **Invite user**

**Note**: The service account doesn't need to "accept" the invite - it becomes active immediately.

#### Step 5: Configure eas.json

```json
{
  "submit": {
    "production": {
      "android": {
        "serviceAccountKeyPath": "./google-play-key.json",
        "track": "internal"
      }
    }
  }
}
```

#### Step 6: Test the Setup

```bash
# Wait a few minutes for permissions to propagate, then:
eas submit --platform android --latest
```

#### Troubleshooting Service Account

| Error | Cause | Fix |
|-------|-------|-----|
| "Permission denied" | Service account not invited to Play Console | Complete Step 4 above |
| "Invalid credentials" | JSON key missing or wrong path | Verify `serviceAccountKeyPath` in eas.json |
| "API not enabled" | Google Play Developer API disabled | Enable in Google Cloud Console |
| "App not found" | Service account not granted access to this app | Add app in Play Console permissions |

### 5.4 Build for Android

```bash
# Production build (generates .aab file)
eas build --platform android --profile production
```

### 5.5 Submit to Google Play

```bash
# Submit to internal testing track
eas submit --platform android --latest

# Or manually upload:
# 1. Download .aab from EAS
# 2. Go to Play Console → Release → Testing → Internal testing
# 3. Create new release and upload .aab
```

### 5.6 Testing Tracks

| Track | Purpose | Reviewers |
|-------|---------|-----------|
| Internal | Team testing | Up to 100 testers, instant |
| Closed | Beta testers | Invite-only, instant |
| Open | Public beta | Anyone can join |
| Production | Live release | All users |

### 5.7 Closed Testing Requirements

For **personal developer accounts created after November 13, 2023**, Google requires:

- **12+ testers** who have opted-in
- **14 consecutive days** of testing
- Before production release is allowed

**Note**: Organization accounts or accounts created before Nov 13, 2023 are exempt.

1. Go to **Testing** → **Closed testing**
2. Create track (e.g., "Alpha testers")
3. Add tester email list (need 12+ real people)
4. Testers must:
   - Accept invite email
   - Join via Google Groups or direct link
   - Download from Play Store (testing version)
   - Actually use the app during the 14-day period

### 5.8 Production Release

After closed testing period:
1. Go to **Production**
2. Create new release
3. Add release notes
4. Select countries/regions
5. Submit for review (typically 1-3 days for first review)

### 5.9 Demo Account for Google Play Review

Similar to Apple, Google may need to test your app's functionality. Set up a demo account for reviewers.

#### Setting Up the Demo Account

1. **Create a dedicated test account**:
   - Email: `googlereviewer@test.com` (or similar)
   - Password: A simple password (e.g., `GoogleReview2025!`)

2. **Disable 2FA/Client Trust** (Critical for Clerk users):
   - Go to [Clerk Dashboard](https://dashboard.clerk.com)
   - Navigate to **Users** → Find your demo account
   - Click on the user → Go to **Settings** tab
   - Enable **"Bypass Client Trust"**
   - This prevents verification prompts on new devices

3. **Pre-populate with sample data**:
   - Add sample recipes so reviewers can test features

4. **Provide credentials in Play Console**:
   - Go to your app → **Policy** → **App content**
   - Under **App access**, select "All or some functionality is restricted"
   - Add login credentials for the demo account

#### Important Notes

- Google reviewers test on various devices, so "Bypass Client Trust" is essential
- Keep demo accounts separate from real user accounts
- Periodically verify demo accounts still work before submissions

---

## 6. OAuth Configuration (Clerk)

### 6.1 The Problem

OAuth on mobile requires special handling because:
- Mobile apps use custom URL schemes (e.g., `yourapp://`)
- OAuth providers redirect back to these schemes
- iOS and Android handle deep links differently

### 6.2 Clerk SSO Setup

```typescript
// In your sign-in screen
import { useSSO } from '@clerk/clerk-expo';
import * as WebBrowser from 'expo-web-browser';
import * as Linking from 'expo-linking';
import { Platform } from 'react-native';

// Required for OAuth to complete properly
WebBrowser.maybeCompleteAuthSession();

// Warm up browser on Android for faster OAuth (optional but recommended)
if (Platform.OS === 'android') {
  WebBrowser.warmUpAsync();
}

export default function SignInScreen() {
  const { startSSOFlow } = useSSO();
  
  const handleOAuthSignIn = async (strategy: 'oauth_apple' | 'oauth_google') => {
    // IMPORTANT: Use Linking.createURL() instead of hardcoded strings
    // This is required for Android on Expo SDK 53+
    const redirectUrl = Linking.createURL('oauth-callback');
    
    const { createdSessionId, setActive } = await startSSOFlow({
      strategy,
      redirectUrl,
    });
    
    if (createdSessionId) {
      await setActive({ session: createdSessionId });
    }
  };
}
```

**Critical for Expo SDK 53+**: Using `Linking.createURL()` instead of a hardcoded string like `'yourapp://oauth-callback'` is essential for Android compatibility. The hardcoded approach stopped working reliably after SDK 53.

### 6.3 iOS Configuration

iOS handles the scheme automatically from `app.json`:

```json
{
  "expo": {
    "scheme": "yourapp"
  }
}
```

### 6.4 Android Configuration (Critical!)

Android requires explicit `intentFilters`:

```json
{
  "expo": {
    "scheme": "yourapp",
    "android": {
      "package": "com.yourcompany.appname",
      "intentFilters": [
        {
          "action": "VIEW",
          "category": ["BROWSABLE", "DEFAULT"],
          "data": [
            {
              "scheme": "yourapp"
            }
          ]
        }
      ]
    }
  }
}
```

**Without this, Android OAuth will crash the app!**

### 6.5 Clerk Dashboard Configuration

1. Go to Clerk Dashboard → **Configure** → **SSO Connections**
2. For each OAuth provider (Google, Apple):
   - Verify redirect URIs include your scheme
   - For development: `yourapp://oauth-callback`

### 6.6 Google OAuth Specific Setup (Web-Based)

For web-based Google Sign-In on Android:

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create or select project
3. Go to **APIs & Services** → **Credentials**
4. Create **OAuth 2.0 Client ID** for Android
5. Add your app's **SHA-1 fingerprint**:

```bash
# Get SHA-1 from EAS
eas credentials --platform android

# Look for "SHA1 Fingerprint" in the output
# Example: 2F:C5:7D:95:1A:2E:20:37:7A:7B:43:BF:4A:E1:FE:25:E1:AE:DE:40
```

6. Add SHA-1 to Google Cloud Console OAuth client

**Note**: If using Clerk's shared credentials, this may not be necessary.

### 6.7 Native Google Sign-In (Alternative for Android)

If web-based Google OAuth doesn't work reliably on Android, you can use the native Google Sign-In SDK instead. This provides a more native experience but requires additional setup.

**Note**: Before implementing native Google Sign-In, make sure your issue is actually OAuth-related. Common Android crashes during sign-in navigation are often caused by other issues like [Reanimated exit animations](#app-crashes-on-navigation-with-reactviewgroup-contains-null-child-new-architecture), not OAuth itself.

#### Step 1: Install the Package

```bash
npm install @react-native-google-signin/google-signin
```

#### Step 2: Add Plugin to app.json

```json
{
  "expo": {
    "plugins": [
      "expo-router",
      "expo-secure-store",
      "expo-web-browser",
      "@react-native-google-signin/google-signin"
    ]
  }
}
```

#### Step 3: Configure Google Cloud Console

**Create Web Application OAuth Client** (for getting tokens):

1. Go to [Google Cloud Console](https://console.cloud.google.com) → **APIs & Services** → **Credentials**
2. Click **Create Credentials** → **OAuth client ID**
3. Select **Web application**
4. Name: `Your App Web Client`
5. Add **Authorized redirect URI**: Your Clerk OAuth callback URL (e.g., `https://your-clerk-domain.clerk.accounts.dev/v1/oauth_callback`)
6. Click **Create** and **copy the Client ID**

**Create Android OAuth Client** (for app verification):

1. Click **Create Credentials** → **OAuth client ID** again
2. Select **Android**
3. Name: `Your App Android`
4. Package name: `com.yourcompany.appname`
5. SHA-1 fingerprint: Get from `eas credentials --platform android`
6. Click **Create**

#### Step 4: Add Environment Variable

Add the **Web Client ID** to EAS:

1. Go to [expo.dev](https://expo.dev) → Your project → **Secrets**
2. Add variable:
   - Name: `EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID`
   - Value: Your Web Client ID (e.g., `123456789-xxx.apps.googleusercontent.com`)
   - Environments: production (and preview/development if needed)

#### Step 5: Configure Clerk with Custom Credentials

1. Go to [Clerk Dashboard](https://dashboard.clerk.com) → **Configure** → **SSO Connections** → **Google**
2. Enable **Use custom credentials**
3. Enter:
   - **Client ID**: Your Web Client ID
   - **Client Secret**: Your Web Client Secret (from Google Cloud Console)
4. **Copy the Authorized Redirect URI** shown in Clerk
5. Add that URI to Google Cloud Console → Web Client → **Authorized redirect URIs**
6. Save in both places

#### Step 6: Update Sign-In Code

```typescript
import { GoogleSignin, statusCodes } from '@react-native-google-signin/google-signin';
import { useClerk } from '@clerk/clerk-expo';
import { Platform } from 'react-native';

// Configure at the top of your file
GoogleSignin.configure({
  webClientId: process.env.EXPO_PUBLIC_GOOGLE_WEB_CLIENT_ID,
  offlineAccess: true,
});

// In your component
const { clerk } = useClerk();

const handleGoogleSignIn = async () => {
  if (Platform.OS === 'android') {
    // Use native Google Sign-In on Android
    await GoogleSignin.hasPlayServices({ showPlayServicesUpdateDialog: true });
    const userInfo = await GoogleSignin.signIn();
    const idToken = userInfo.data?.idToken;
    
    if (!idToken) {
      throw new Error('No ID token received from Google');
    }

    // Exchange token with Clerk
    const clerkClient = clerk as any;
    if (clerkClient.authenticateWithGoogleOneTap) {
      const response = await clerkClient.authenticateWithGoogleOneTap({ token: idToken });
      if (response.createdSessionId) {
        await clerk.setActive({ session: response.createdSessionId });
        // Navigate to home
      }
    }
  } else {
    // Use web-based SSO on iOS (works fine there)
    // ... existing startSSOFlow code
  }
};
```

#### Step 7: Build and Test

```bash
# Must create a new build after adding native module
eas build --platform android --profile production
```

**Important Notes**:
- Native Google Sign-In requires a **new native build** - OTA updates won't work
- The Android client in Google Cloud Console doesn't give you a client ID to use in code - it just registers your app
- Always use the **Web Client ID** in your app code

---

## 7. Deep Linking Setup

### 7.1 URL Scheme (Basic)

For custom scheme links like `yourapp://`:

```json
// app.json
{
  "expo": {
    "scheme": "yourapp",
    "android": {
      "intentFilters": [
        {
          "action": "VIEW",
          "category": ["BROWSABLE", "DEFAULT"],
          "data": [{ "scheme": "yourapp" }]
        }
      ]
    }
  }
}
```

### 7.2 Universal Links (iOS) / App Links (Android)

For `https://` links that open your app:

#### iOS (apple-app-site-association)

Host at `https://yourdomain.com/.well-known/apple-app-site-association`:

```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "TEAM_ID.com.yourcompany.appname",
        "paths": ["/invite/*", "/recipe/*"]
      }
    ]
  }
}
```

#### Android (assetlinks.json)

Host at `https://yourdomain.com/.well-known/assetlinks.json`:

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.yourcompany.appname",
      "sha256_cert_fingerprints": ["YOUR_SHA256_FINGERPRINT"]
    }
  }
]
```

#### app.json Configuration

```json
{
  "expo": {
    "android": {
      "intentFilters": [
        {
          "action": "VIEW",
          "autoVerify": true,
          "category": ["BROWSABLE", "DEFAULT"],
          "data": [
            {
              "scheme": "https",
              "host": "yourdomain.com",
              "pathPrefix": "/invite"
            }
          ]
        }
      ]
    },
    "ios": {
      "associatedDomains": ["applinks:yourdomain.com"]
    }
  }
}
```

---

## 8. Environment Variables

### 8.1 EAS Environment Variables

Set in EAS dashboard or `eas.json`:

```json
// eas.json
{
  "build": {
    "production": {
      "env": {
        "EXPO_PUBLIC_API_URL": "https://api.yourapp.com",
        "EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY": "pk_live_..."
      }
    }
  }
}
```

Or via EAS dashboard:
1. Go to [expo.dev](https://expo.dev)
2. Select your project
3. Go to **Secrets**
4. Add variables with appropriate visibility

### 8.2 Visibility Levels

| Level | Description | Use For |
|-------|-------------|---------|
| Plain text | Visible in logs | Public keys, API URLs |
| Sensitive | Hidden in logs | Private keys, secrets |
| Secret | Not in build logs | Most secure |

### 8.3 Accessing in Code

```typescript
// Use EXPO_PUBLIC_ prefix for client-side access
const apiUrl = process.env.EXPO_PUBLIC_API_URL;
const clerkKey = process.env.EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY;
```

---

## 9. Version Management

### 9.1 Version vs Build Number

| Field | Purpose | Example | When to Increment |
|-------|---------|---------|-------------------|
| `version` | User-facing version | `2.1.0` | Feature releases |
| `buildNumber` (iOS) | Internal build ID | `31` | Every build |
| `versionCode` (Android) | Internal build ID | `8` | Every build |

### 9.2 Semantic Versioning

```
MAJOR.MINOR.PATCH
  │     │     │
  │     │     └── Bug fixes (2.1.1)
  │     └──────── New features (2.2.0)
  └────────────── Breaking changes (3.0.0)
```

### 9.3 Auto-Increment with EAS

```json
// eas.json
{
  "cli": {
    "appVersionSource": "remote"
  },
  "build": {
    "production": {
      "autoIncrement": true
    }
  }
}
```

This automatically increments `buildNumber`/`versionCode` on each build.

### 9.4 Manual Version Update

```json
// app.json
{
  "expo": {
    "version": "2.2.0",
    "ios": {
      "buildNumber": "31"
    },
    "android": {
      "versionCode": 8
    }
  }
}
```

---

## 10. Android Debugging with ADB

When debugging Android-specific issues, **do not** repeatedly build and submit to Google Play. Instead, use ADB (Android Debug Bridge) with debug APK builds for fast local testing.

### 10.1 Why This Matters

| Approach | Time per Test | Feedback Loop |
|----------|---------------|---------------|
| Build + Submit to Play Store | 20-30 minutes | Very slow, frustrating |
| Debug APK + ADB Install | 10-15 minutes | Fast, immediate |

### 10.2 Prerequisites

#### Install ADB

```bash
# macOS (via Homebrew)
brew install android-platform-tools

# Verify installation
adb version
```

#### Enable USB Debugging on Android Device

1. Go to **Settings** → **About phone**
2. Tap **Build number** 7 times to enable Developer Mode
3. Go back to **Settings** → **Developer options**
4. Enable **USB debugging**

**Samsung devices**: If USB debugging is grayed out and says "Blocked by Auto Blocker":
1. Go to **Settings** → **Security and privacy** → **Auto Blocker**
2. Turn off **Auto Blocker**
3. Return to Developer options and enable USB debugging

#### Connect Device

```bash
# Check connected devices
adb devices

# Should show your device:
# List of devices attached
# XXXXXXXX    device
```

If it shows "unauthorized", check your phone for a USB debugging permission prompt and tap "Allow".

### 10.3 Create Debug APK Build Profile

Add a debug profile to `eas.json` for faster APK builds:

```json
{
  "build": {
    "android-debug": {
      "distribution": "internal",
      "android": {
        "buildType": "apk",
        "gradleCommand": ":app:assembleRelease"
      },
      "env": {
        "SENTRY_ALLOW_FAILURE": "true"
      }
    }
  }
}
```

**Key differences from production**:
- `buildType: "apk"` - Creates an APK file (not AAB) that can be installed directly
- Faster to install on device than going through Play Store

### 10.4 Build and Install Debug APK

```bash
# Build debug APK
eas build --platform android --profile android-debug

# Once complete, download the APK
curl -L -o ~/debug-app.apk "APK_URL_FROM_BUILD"

# Install on connected device (replace existing if installed)
adb install -r ~/debug-app.apk
```

**Tip**: You can also open the APK URL directly on your phone's browser to download and install.

### 10.5 Capture Crash Logs with Logcat

This is the most important debugging tool. When your app crashes, logcat captures the exact error.

#### Basic Crash Capture

```bash
# Clear old logs and start capturing
adb logcat -c && adb logcat "AndroidRuntime:E" "ReactNative:E" "ReactNativeJS:E" "*:F" | tee ~/crash_log.txt
```

This command:
- `-c` - Clears existing logs
- `AndroidRuntime:E` - Shows Android runtime errors
- `ReactNative:E` - Shows React Native bridge errors
- `ReactNativeJS:E` - Shows JavaScript errors
- `*:F` - Shows all fatal errors
- `| tee ~/crash_log.txt` - Saves to file while also displaying

#### Workflow

1. Start the logcat command (it will wait for logs)
2. Open your app on the Android device
3. Trigger the crash
4. The crash stack trace appears in terminal
5. Press `Ctrl+C` to stop and review `~/crash_log.txt`

#### Example Crash Output

```
--------- beginning of crash
01-25 15:26:59.216 12683 12683 E AndroidRuntime: FATAL EXCEPTION: main
01-25 15:26:59.216 12683 12683 E AndroidRuntime: Process: com.yourcompany.appname, PID: 12683
01-25 15:26:59.216 12683 12683 E AndroidRuntime: java.lang.IllegalStateException: ReactViewGroup contains null child...
01-25 15:26:59.216 12683 12683 E AndroidRuntime: 	at android.view.ViewGroup.dispatchGetDisplayList(ViewGroup.java:4761)
...
```

### 10.6 Common ADB Commands

```bash
# List connected devices
adb devices

# Install APK (replace existing)
adb install -r app.apk

# Uninstall app
adb uninstall com.yourcompany.appname

# View all logs (verbose - lots of output!)
adb logcat

# View only error-level logs
adb logcat '*:E'

# Filter by your app's package
adb logcat --pid=$(adb shell pidof com.yourcompany.appname)

# Clear log buffer
adb logcat -c

# Take screenshot
adb shell screencap /sdcard/screenshot.png && adb pull /sdcard/screenshot.png

# Record screen
adb shell screenrecord /sdcard/video.mp4
# (Ctrl+C to stop, then: adb pull /sdcard/video.mp4)
```

### 10.7 Debugging Workflow Summary

```
1. Make code changes
2. Build debug APK: eas build --platform android --profile android-debug
3. Download APK
4. Start logcat: adb logcat -c && adb logcat "AndroidRuntime:E" "*:F"
5. Install APK: adb install -r app.apk
6. Test and trigger crash
7. Read crash logs in terminal
8. Fix issue and repeat
```

**This workflow is 10x faster than submitting to Google Play each time!**

---

## 11. Release Process Checklist

### Pre-Release

```
□ Update version in app.json
□ Update RELEASE-NOTES.txt with What's New
□ Test on physical devices (iOS + Android)
□ Run linting and type checks
□ Commit all changes to git
```

### Build Phase

```
□ Build iOS: eas build --platform ios --profile production
□ Build Android: eas build --platform android --profile production
□ Verify builds complete without errors
```

### iOS Submission

```
□ Submit: eas submit --platform ios --latest
□ Wait for TestFlight processing (5-30 min)
□ Test on TestFlight
□ In App Store Connect:
  □ Select build
  □ Add What's New text
  □ Update description if needed
  □ Add for Review
□ Wait for review (24-48 hours typically)
□ Release (manual or automatic)
```

### Android Submission

```
□ Submit: eas submit --platform android --latest
  - Or manually upload .aab to Play Console
□ In Play Console:
  □ Create release in appropriate track
  □ Add release notes
  □ Submit for review
□ Wait for review (1-3 days for new apps)
□ Promote through tracks: Internal → Closed → Production
```

### Post-Release

```
□ Verify app appears in stores
□ Download and test production app
□ Monitor crash reports (Sentry, Crashlytics)
□ Respond to user reviews
□ Push changes to GitHub
□ Create git tag: git tag v2.2.0
```

---

## 12. Common Issues & Solutions

### App Review Rejections

#### "Unable to sign in with demo account" (Guideline 2.1)

**Cause**: Demo account doesn't exist, wrong credentials, or 2FA/Client Trust blocking login  
**Fix**:
1. Verify account exists in Clerk dashboard
2. Test login yourself before submitting
3. Enable "Bypass Client Trust" for the demo user in Clerk
4. Ensure password is correct in App Store Connect / Play Console

#### "Metadata includes third-party platform references" (Guideline 2.3.10)

**Cause**: "What's New" text mentions Android, Google Play, or other platforms  
**Fix**: Remove all references to other platforms from your App Store metadata. Focus only on iOS features.

### iOS Issues

#### "App is stuck in Processing" in TestFlight

**Cause**: Apple's servers are slow or there's an issue  
**Fix**: Wait 30-60 minutes. If still stuck, contact Apple support.

#### "Invalid Binary" rejection

**Cause**: Usually missing privacy declarations  
**Fix**: Add required `infoPlist` entries:

```json
{
  "ios": {
    "infoPlist": {
      "ITSAppUsesNonExemptEncryption": false,
      "NSCameraUsageDescription": "Why you need camera",
      "NSPhotoLibraryUsageDescription": "Why you need photos"
    }
  }
}
```

#### Build fails with signing errors

**Cause**: Certificate or provisioning profile issues  
**Fix**: 
```bash
eas credentials --platform ios
# Follow prompts to regenerate credentials
```

#### "You've already submitted this build"

**Cause**: Trying to submit the same build number twice  
**Fix**: Build numbers must be unique. Build a new version:
```bash
eas build --platform ios --profile production
# Auto-increment will create new build number
```

### Android Issues

#### App crashes on navigation with "ReactViewGroup contains null child" (New Architecture)

**Symptoms**: App crashes immediately when navigating to certain screens on Android. No crash on iOS.

**Error in logcat**:
```
FATAL EXCEPTION: main
java.lang.IllegalStateException: ReactViewGroup contains null child at index N when traversal in dispatchGetDisplayList, the view may have been removed.
```

**Cause**: This is a race condition in React Native's New Architecture (Fabric renderer) on Android. It occurs when:
1. A component uses Reanimated's `exiting` animations (e.g., `exiting={FadeOut}`)
2. The component conditionally renders (returns `null` based on state/route)
3. During navigation, the component unmounts while Android's rendering system is still drawing

The `exiting` animation tries to animate the view out, but Fabric's rendering pipeline has already removed the view from the hierarchy, causing the crash.

**Fix**: Remove `exiting` animations from conditionally rendered components:

```typescript
// BAD - causes crash on Android with New Architecture
import { FadeIn, FadeOut } from 'react-native-reanimated';

function FloatingButton() {
  if (!shouldShow) return null;
  
  return (
    <Animated.View
      entering={FadeIn}
      exiting={FadeOut}  // ❌ This causes the crash!
    >
      {/* content */}
    </Animated.View>
  );
}

// GOOD - safe for New Architecture
function FloatingButton() {
  if (!shouldShow) return null;
  
  return (
    <Animated.View
      entering={FadeIn}
      // No exiting animation - component just disappears
    >
      {/* content */}
    </Animated.View>
  );
}
```

**Important notes**:
- `entering` animations are safe (component is mounting, not unmounting)
- This only affects Android with New Architecture (`newArchEnabled: true`)
- iOS does not have this issue
- You cannot disable New Architecture if using Reanimated 4.x (it requires Fabric)
- Use [Section 10 (Android Debugging with ADB)](#10-android-debugging-with-adb) to diagnose these crashes locally

#### App crashes/closes on Google Sign-In (Expo SDK 53+)

**Cause**: Expo SDK 53+ changed how `expo-web-browser` handles OAuth redirects on Android. Hardcoded redirect URLs no longer work reliably.

**Fix**: Use `Linking.createURL()` instead of hardcoded strings:

```typescript
// BAD - doesn't work on Android SDK 53+
redirectUrl: 'yourapp://oauth-callback',

// GOOD - works on all platforms
import * as Linking from 'expo-linking';
const redirectUrl = Linking.createURL('oauth-callback');
```

Also add browser warm-up for Android:

```typescript
import * as WebBrowser from 'expo-web-browser';
import { Platform } from 'react-native';

// At top of file, outside component
WebBrowser.maybeCompleteAuthSession();

if (Platform.OS === 'android') {
  WebBrowser.warmUpAsync();
}
```

**Important**: This requires a new native build after making the change.

#### App crashes on Google Sign-In (Missing Intent Filters)

**Cause**: Missing `intentFilters` for deep linking  
**Fix**: Add to `app.json`:

```json
{
  "android": {
    "intentFilters": [
      {
        "action": "VIEW",
        "category": ["BROWSABLE", "DEFAULT"],
        "data": [{ "scheme": "yourapp" }]
      }
    ]
  }
}
```

**Important**: Requires new build after adding!

#### OAuth hangs after consent screen

**Cause**: Redirect URL mismatch  
**Fix**: 
1. Verify `scheme` in app.json matches `redirectUrl` in code
2. Verify `intentFilters` are configured
3. Rebuild the app

#### "App not installed" error

**Cause**: Signing key mismatch or corrupt download  
**Fix**: Uninstall existing app, download fresh from Play Store

#### Upload fails with "Version code already used"

**Cause**: Build number (versionCode) must always increase  
**Fix**: 
```json
{
  "android": {
    "versionCode": 9  // Higher than any previous upload
  }
}
```

#### "eas submit" fails with permission error

**Cause**: Service account not invited to Play Console or missing permissions  
**Fix**: 
1. Go to **Users and permissions** in Play Console
2. Invite the service account email as a new user
3. Grant **Release apps to testing tracks** and **Release to production** permissions for your app
4. Wait a few minutes for permissions to propagate

See [Section 5.3 (Service Account for Automated Uploads)](#53-service-account-for-automated-uploads) for complete setup.

### OAuth Issues

#### "Cannot make deep link into standalone app"

**Cause**: `scheme` not configured in app.json  
**Fix**: Add scheme at expo root level:

```json
{
  "expo": {
    "scheme": "yourapp"
  }
}
```

#### OAuth works on iOS but not Android

**Cause**: Android requires explicit intent filters  
**Fix**: See Android configuration in [OAuth Configuration](#6-oauth-configuration-clerk)

#### OAuth redirect URL mismatch

**Cause**: Code uses different URL than configured  
**Fix**: Ensure consistency:

```typescript
// Code
redirectUrl: 'yourapp://oauth-callback'

// app.json scheme
"scheme": "yourapp"

// Clerk dashboard
// Allowed redirect: yourapp://oauth-callback
```

### Build Issues

#### Build queued for hours

**Cause**: Free tier has limited build capacity  
**Fix**: 
1. Wait (free tier can have long queues)
2. Upgrade to EAS Priority builds ($99/month)
3. Build during off-peak hours (weekends, nights)

#### "Out of memory" during build

**Cause**: Large assets or too many dependencies  
**Fix**:
1. Optimize images
2. Remove unused dependencies
3. Use `expo-optimize` command

---

## 13. Cost Overview

### Required Costs

| Item | Cost | Frequency |
|------|------|-----------|
| Apple Developer Program | $99 | Annual |
| Google Play Developer | $25 | One-time |

### Optional Costs

| Service | Free Tier | Paid |
|---------|-----------|------|
| EAS Build | 30 builds/month | $99/month (priority) |
| EAS Submit | Included | Included |
| EAS Update (OTA) | 1,000 users | $99/month |

### Build Estimates

| Scenario | Monthly Builds | Cost |
|----------|----------------|------|
| Solo developer | 5-10 | Free |
| Small team | 15-30 | Free |
| Active development | 30-50 | $99/month |
| Enterprise | 100+ | Custom pricing |

---

## Quick Reference

### Essential Commands

```bash
# Login
eas login

# Build iOS
eas build --platform ios --profile production

# Build Android
eas build --platform android --profile production

# Build both
eas build --platform all --profile production

# Build Android debug APK (for local testing with ADB)
eas build --platform android --profile android-debug

# Submit iOS
eas submit --platform ios --latest

# Submit Android
eas submit --platform android --latest

# Check credentials
eas credentials --platform ios
eas credentials --platform android

# View builds
eas build:list

# Android debugging (see Section 10)
adb devices                    # List connected devices
adb install -r app.apk         # Install APK
adb logcat '*:E'               # View error logs
```

### Key Files

| File | Purpose |
|------|---------|
| `app.json` | App configuration |
| `eas.json` | Build profiles |
| `google-play-key.json` | Android automated upload (gitignored - see [5.3](#53-service-account-for-automated-uploads)) |

### Important URLs

| Service | URL |
|---------|-----|
| Expo Dashboard | [expo.dev](https://expo.dev) |
| App Store Connect | [appstoreconnect.apple.com](https://appstoreconnect.apple.com) |
| Google Play Console | [play.google.com/console](https://play.google.com/console) |
| Apple Developer | [developer.apple.com](https://developer.apple.com) |

---

*Last updated: January 25, 2026*
