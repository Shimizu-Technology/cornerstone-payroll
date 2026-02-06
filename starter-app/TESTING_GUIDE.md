# Testing Guide

A comprehensive guide for setting up AI-assisted testing (Agent Browser) and automated E2E testing (Playwright) in React + Rails projects.

---

## Table of Contents
1. [Testing Philosophy](#1-testing-philosophy)
2. [The Testing Stack](#2-the-testing-stack)
3. [Agent Browser Setup](#3-agent-browser-setup)
4. [Playwright Setup](#4-playwright-setup)
5. [Test Account & Authentication](#5-test-account--authentication)
6. [Writing E2E Tests](#6-writing-e2e-tests)
7. [Running Tests](#7-running-tests)
8. [AI-Assisted Testing Workflow](#8-ai-assisted-testing-workflow)
9. [Integration with Planning](#9-integration-with-planning)
10. [Common Patterns](#10-common-patterns)
11. [Troubleshooting](#11-troubleshooting)
12. [Comprehensive User Flow Testing](#12-comprehensive-user-flow-testing)
13. [Test-Alongside Development](#13-test-alongside-development)
14. [Common Bugs & How to Prevent Them](#14-common-bugs--how-to-prevent-them)

---

## 1. Testing Philosophy

### Check Existing Patterns First

**CRITICAL: Before writing new code, review existing patterns in the codebase.**

This is especially important for:
- **API service files** - Check the axios base URL configuration before writing new services
- **Component files** - See how similar components are structured
- **Utility functions** - Match existing naming and patterns

**Example mistake to avoid:**
```typescript
// api.ts has: baseURL: `${API_BASE_URL}/api/v1`

// ❌ WRONG - creates doubled URL: /api/v1/api/v1/admin/products
api.get('/api/v1/admin/products')

// ✅ CORRECT - baseURL already has /api/v1
api.get('/admin/products')
```

**Rule: Spend 2 minutes reviewing existing patterns before writing new code. It prevents hours of debugging.**

### Right-Sized Testing

Don't aim for 100% coverage. Focus on:

| Priority | What to Test | Why |
|----------|-------------|-----|
| **P0** | Critical user flows | Broken = business impact |
| **P1** | Authentication/authorization | Security critical |
| **P2** | Complex forms/wizards | Easy to break |
| **P3** | Edge cases that have broken before | Prevent regressions |

### The Testing Pyramid — Priority Order

When AI (or any developer) writes tests, write them in THIS order. The base of the pyramid catches the most bugs with the least effort:

```
        ┌─────────────────┐
        │   Manual QA     │  ← You + stakeholders (final approval)
        ├─────────────────┤
        │  AI Verification │  ← Agent Browser (quick sanity checks)
        ├─────────────────┤
        │    E2E Tests     │  ← Playwright (critical flows ONLY)
        ├─────────────────┤
   ★ → │ Request Specs    │  ← RSpec API contract tests (THE BACKBONE)
        ├─────────────────┤
   ★ → │ Model/Unit Tests │  ← Business logic, validations, calculations
        └─────────────────┘
              ▲ START HERE
```

> **Key insight:** Request specs (API contract tests) and model specs catch ~70% of bugs, run in seconds, and never flake. E2E tests are important but slow, brittle, and should only cover critical user flows. Don't skip straight to E2E — build the foundation first.

### Test Priority for AI Agents

When an AI agent is writing tests for a feature, follow this order:

| Priority | Test Type | What It Catches | Speed | Reliability |
|----------|-----------|----------------|-------|-------------|
| **1st** | **Request specs** (RSpec) | API contracts — does the endpoint return the right data? Does it reject bad input? Auth working? | ⚡ Fast | 🟢 Very reliable |
| **2nd** | **Model specs** (RSpec) | Business logic — price calculations, validations, state transitions, edge cases | ⚡ Fast | 🟢 Very reliable |
| **3rd** | **E2E tests** (Playwright) | Full user flows — can a user actually browse → add to cart → checkout? | 🐌 Slow | 🟡 Can be flaky |
| **4th** | **AI Verification** | Visual/UX — does the page look right after changes? | ⚡ Fast | 🟡 Subjective |

**Example for an ordering system:**
```
1st: Request spec — POST /api/v1/orders with valid items returns 201
     Request spec — POST /api/v1/orders with missing required modifier returns 422
     Request spec — GET /api/v1/menu returns all categories with items

2nd: Model spec — Order#calculate_total sums base prices + modifier adjustments
     Model spec — Order validates required modifier groups are selected
     Model spec — MenuItem.available scope excludes disabled items

3rd: E2E — User can browse menu → customize sandwich → add to cart → checkout → see confirmation
     (This ONE test covers the critical path. Don't write 20 E2E tests.)
```

### When to Use Each

| Layer | When | Examples |
|-------|------|----------|
| **Model/Unit Tests** | Pure logic, utilities, calculations, validations | Price calculation, modifier validation, `formatDate()` |
| **Request Specs** | Every API endpoint, auth/permission checks | POST /orders, GET /menu, admin-only endpoints |
| **E2E Tests** | Critical user flows only, regressions | Login, checkout, form submission |
| **AI Verification** | After making changes, quick sanity check | "Does this page still render?" |
| **Manual QA** | UX review, edge cases, final approval | Before major releases |

---

## 2. The Testing Stack

### Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Your Application                          │
│     Frontend (React)              Backend (Rails)            │
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
┌───────────────────┐    ┌────────────────────────┐
│   Agent Browser   │    │      Playwright        │
│  (AI Verification)│    │   (Automated E2E)      │
│                   │    │                        │
│  • Quick checks   │    │  • Regression tests    │
│  • Visual verify  │    │  • CI/CD integration   │
│  • Interactive    │    │  • Auth handling       │
└───────────────────┘    └────────────────────────┘
```

### Technology Choices

| Tool | Purpose | Why This One |
|------|---------|--------------|
| **Agent Browser** | AI-assisted browser testing | Designed for AI agents, ref system |
| **Playwright** | E2E test framework | Modern, fast, great auth support |
| **Vitest** | Frontend unit tests | Fast, Vite-native, good DX |
| **RSpec** | Backend unit tests | Ruby standard, expressive |

---

## 3. Agent Browser Setup

[Agent Browser](https://github.com/vercel-labs/agent-browser) is a CLI tool that lets AI agents control a browser.

### Installation

```bash
# Install globally
npm install -g agent-browser

# Or install in project
npm install agent-browser --save-dev
```

### Verify Installation

```bash
agent-browser --version
agent-browser --help
```

### Basic Usage

```bash
# Open a page
agent-browser open http://localhost:5173

# Get page snapshot (AI-readable structure)
agent-browser snapshot -i

# Get snapshot as JSON (for AI parsing)
agent-browser snapshot -i --json

# Click an element (using ref from snapshot)
agent-browser click @e1

# Fill a text field
agent-browser fill @e3 "test@example.com"

# Take a screenshot
agent-browser screenshot

# Get text content
agent-browser get text @e1
```

### The Ref System

Agent Browser uses refs (`@e1`, `@e2`, etc.) to identify elements:

```bash
# 1. Get snapshot with refs
agent-browser snapshot -i
# Output:
# - heading "Welcome" [ref=e1]
# - textbox "Email" [ref=e2]
# - button "Submit" [ref=e3]

# 2. Use refs to interact
agent-browser fill @e2 "test@example.com"
agent-browser click @e3
```

**Why refs are better than CSS selectors:**
- Deterministic (exact element from snapshot)
- No DOM re-query needed
- AI-friendly (snapshot → ref → action)

### Headed Mode (Visual Debugging)

```bash
# Show the browser window
agent-browser open http://localhost:5173 --headed
```

### Authentication with Headers

```bash
# Pass auth headers (scoped to origin)
agent-browser open http://localhost:5173 --headers '{"Authorization": "Bearer <token>"}'
```

### Cursor Integration

Add to your `.cursor/rules/project.mdc`:

```markdown
## AI Testing with Agent Browser

After making frontend changes, verify with:
1. `agent-browser open http://localhost:5173` - Navigate
2. `agent-browser snapshot -i` - Get interactive elements
3. Test the specific change using refs
4. `agent-browser screenshot` - Capture result if needed
```

---

## 4. Playwright Setup

### Installation

```bash
cd frontend
npm init playwright@latest
```

When prompted:
- TypeScript: Yes
- Tests folder: `e2e`
- GitHub Actions: Yes (optional)
- Install browsers: Yes

### Project Structure

```
frontend/
├── e2e/
│   ├── auth.setup.ts       # Login and save session
│   ├── intake-form.spec.ts # Intake form tests
│   ├── login.spec.ts       # Auth tests
│   └── ...
├── playwright.config.ts    # Playwright config
└── playwright/
    └── .auth/              # Saved auth state (gitignored)
```

### Configuration

```typescript
// frontend/playwright.config.ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  projects: [
    // Setup project - runs first, saves auth state
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    
    // Main tests - use saved auth state
    {
      name: 'chromium',
      use: { 
        ...devices['Desktop Chrome'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },
    
    // Mobile tests
    {
      name: 'mobile',
      use: { 
        ...devices['iPhone 13'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },
  ],

  // Start dev server before tests
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: !process.env.CI,
  },
});
```

### Add to .gitignore

```gitignore
# Playwright
/test-results/
/playwright-report/
/blob-report/
/playwright/.cache/
/playwright/.auth/
```

### NPM Scripts

```json
// package.json
{
  "scripts": {
    "test": "playwright test",
    "test:ui": "playwright test --ui",
    "test:headed": "playwright test --headed",
    "test:debug": "playwright test --debug"
  }
}
```

---

## 5. Test Account & Authentication

### Strategy Overview

1. **Create a test user** in your auth system (Clerk)
2. **Sign in once** to create their database record
3. **Assign the correct role** in your database
4. **Store credentials** in your `.env` file
5. **Playwright uses saved session** (no login per test)

### Step 1: Create Test User

**If using an invite-only system (recommended):**
1. First, invite the user through **your app's admin dashboard** (e.g., `/admin/users`)
2. Set their role to **Admin** during invitation
3. Then go to **Clerk Dashboard → Users → + Create user**
4. Use the **same email** you invited
5. Set a password (you'll need this for tests)

**If NOT using invite-only:**
1. Go to Clerk Dashboard → Users
2. Click **"+ Create user"**
3. Fill in:
   - **Email**: `test-admin@yourcompany.com` (can be fake for dev)
   - **Password**: Strong password (you'll need this later)
   - **First Name**: `Test`
   - **Last Name**: `Admin`
4. Click **Create**

### Step 2: Enable "Bypass Client Trust" (Critical!)

By default, Clerk's "Client Trust" feature requires email verification when signing in from a new device. **This will block automated tests.** To disable it for test users:

1. In Clerk Dashboard → Users → Click on your test user
2. Go to the **Settings** tab (next to Profile)
3. Find **"Bypass Client Trust"** and toggle it **ON**
4. This allows the test user to sign in without device verification

> **Why is this needed?** Clerk's Client Trust sends a verification code to the user's email whenever they sign in from a new device/browser. Since test environments are always "new devices," this blocks automated login. Bypassing it for specific test users solves this without reducing security for real users.

### Step 3: Store Credentials in .env

Add the test credentials to your existing `frontend/.env` file (already gitignored):

```bash
# frontend/.env

# ... your existing app config ...
VITE_API_URL=http://localhost:3000
VITE_CLERK_PUBLISHABLE_KEY=pk_test_...

# Test credentials (add these)
TEST_USER_EMAIL=test-admin@yourcompany.com
TEST_USER_PASSWORD=your-password-from-step-1
```

**Note:** You can also use a separate `.env.test` file if you prefer (requires adding `dotenv` to Playwright config).

### Step 4: Sign In Once to Create Database Record

1. Start your local servers:
   ```bash
   # Terminal 1
   cd backend && rails server
   
   # Terminal 2  
   cd frontend && npm run dev
   ```

2. Go to `http://localhost:5173` and sign in with the test user
3. This creates their record in your database

### Step 5: Assign Admin Role

**If using an invite-only system:** Skip this step! When you invited the user through your admin dashboard (Step 1), you already assigned their role. The user record already exists with the correct role, and signing in just links their Clerk ID.

**If NOT using invite-only (auto-create users on sign-in):** Manually assign the role:

```bash
cd backend
rails runner "
  user = User.find_by(email: 'test-admin@yourcompany.com')
  if user
    user.update(role: 'admin')
    puts '✅ User updated to admin!'
  else
    puts '❌ User not found - make sure they signed in first'
  end
"
```

### Step 6: Verify Setup

Your test account is ready when:
- [ ] User exists in Clerk dashboard
- [ ] "Bypass Client Trust" is enabled for the user
- [ ] Credentials are in `frontend/.env`
- [ ] User has signed in at least once
- [ ] User has admin role in database

### Multiple Test Users (Optional)

Start with one admin user. Add more later if needed:

| User | Role | Purpose |
|------|------|---------|
| `test-admin@...` | Admin | Full access testing |
| `test-employee@...` | Employee | Role restriction testing |
| `test-client@...` | Client | Client portal testing |

### Auth Setup Test (Playwright)

**Important Clerk-specific notes:**
- **Click your app's login button** (e.g., "Staff Login") instead of navigating directly to protected routes like `/admin` - this avoids Google OAuth redirect issues
- Use specific selectors to avoid clicking "Continue with Google"
- After login, navigate to admin area manually (don't expect auto-redirect)

```typescript
// frontend/e2e/auth.setup.ts
import { test as setup, expect } from '@playwright/test';

const authFile = 'playwright/.auth/user.json';

setup('authenticate', async ({ page }) => {
  const email = process.env.TEST_USER_EMAIL;
  const password = process.env.TEST_USER_PASSWORD;
  
  if (!email || !password) {
    console.log('⚠️ No test credentials found. Skipping auth setup.');
    await page.context().storageState({ path: authFile });
    return;
  }

  console.log(`🔐 Authenticating as ${email}...`);

  // Navigate to homepage
  await page.goto('/');
  
  // Click your app's login button (NOT directly to /admin)
  await page.click('a:has-text("Staff Login")');
  
  // Wait for Clerk sign-in form
  await page.waitForSelector('input[name="identifier"]', { timeout: 10000 });
  
  // Fill email
  await page.fill('input[name="identifier"]', email);
  await page.waitForTimeout(300);
  
  // Click Continue (but NOT "Continue with Google")
  const continueButton = page.locator('button:has-text("Continue")').filter({ hasNotText: 'Google' });
  await continueButton.click();
  
  // Wait for password field to be enabled
  await page.waitForSelector('input[name="password"]:not([disabled])', { timeout: 10000 });
  await page.fill('input[name="password"]', password);
  await page.waitForTimeout(300);
  
  // Submit
  const submitButton = page.locator('button:has-text("Continue")').filter({ hasNotText: 'Google' });
  await submitButton.click();
  
  // Wait for login to complete (look for Dashboard link)
  await page.waitForSelector('a:has-text("Dashboard")', { timeout: 15000 });
  
  // Navigate to admin area
  await page.click('a:has-text("Dashboard")');
  await page.waitForURL('**/admin**', { timeout: 10000 });
  
  // Verify we're on dashboard
  await expect(page.locator('h1:has-text("Dashboard")').first()).toBeVisible({ timeout: 10000 });
  
  console.log('✅ Authentication successful!');
  
  // Save auth state
  await page.context().storageState({ path: authFile });
});
```

### Use Auth in Tests

```typescript
// frontend/e2e/dashboard.spec.ts
import { test, expect } from '@playwright/test';

// This test uses the saved auth state automatically (via config)
test('dashboard shows client list', async ({ page }) => {
  await page.goto('/admin');
  
  // Already logged in!
  await expect(page.locator('h1')).toContainText('Dashboard');
});
```

### Alternative: Backend Test Token

For API testing or simpler auth, create a test endpoint:

```ruby
# backend/config/routes.rb (development only!)
if Rails.env.development? || Rails.env.test?
  post '/api/v1/auth/test_login', to: 'auth#test_login'
end
```

```ruby
# backend/app/controllers/api/v1/auth_controller.rb
def test_login
  return head :not_found unless Rails.env.development? || Rails.env.test?
  
  user = User.find_by(email: params[:email])
  if user
    # Generate a test token (your token generation logic)
    token = generate_test_token(user)
    render json: { token: token }
  else
    render json: { error: 'User not found' }, status: :not_found
  end
end
```

---

## 6. Writing E2E Tests

### Test Structure

```typescript
import { test, expect } from '@playwright/test';

test.describe('Feature Name', () => {
  test.beforeEach(async ({ page }) => {
    // Setup before each test
    await page.goto('/starting-page');
  });

  test('should do something specific', async ({ page }) => {
    // Arrange - setup state
    
    // Act - perform actions
    await page.click('button:has-text("Submit")');
    
    // Assert - verify results
    await expect(page.locator('.success-message')).toBeVisible();
  });
});
```

### Example: Intake Form Test

```typescript
// frontend/e2e/intake-form.spec.ts
import { test, expect } from '@playwright/test';

test.describe('Client Intake Form', () => {
  test('completes full intake submission', async ({ page }) => {
    // Navigate to intake form
    await page.goto('/intake');
    
    // Step 1: Client Information
    await page.fill('[name="firstName"]', 'John');
    await page.fill('[name="lastName"]', 'Doe');
    await page.fill('[name="email"]', 'john.doe@example.com');
    await page.fill('[name="phone"]', '671-555-1234');
    await page.click('button:has-text("Next")');
    
    // Step 2: Tax Filing Info
    await page.selectOption('[name="taxYear"]', '2025');
    await page.click('label:has-text("Single")');
    await page.click('button:has-text("Next")');
    
    // ... continue through steps ...
    
    // Final step: Authorization
    await page.check('[name="confirmAccuracy"]');
    await page.fill('[name="signature"]', 'John Doe');
    await page.click('button:has-text("Submit")');
    
    // Verify success
    await expect(page).toHaveURL(/\/intake\/success/);
    await expect(page.locator('text=Thank you')).toBeVisible();
  });

  test('shows validation errors for required fields', async ({ page }) => {
    await page.goto('/intake');
    
    // Try to proceed without filling required fields
    await page.click('button:has-text("Next")');
    
    // Verify errors shown
    await expect(page.locator('text=First name is required')).toBeVisible();
    await expect(page.locator('text=Last name is required')).toBeVisible();
  });

  test('kiosk mode hides navigation', async ({ page }) => {
    await page.goto('/intake?mode=kiosk');
    
    // Navigation should not be visible
    await expect(page.locator('nav')).not.toBeVisible();
    
    // Form should still work
    await expect(page.locator('text=Client Information')).toBeVisible();
  });
});
```

### Example: Admin Dashboard Test

```typescript
// frontend/e2e/admin-dashboard.spec.ts
import { test, expect } from '@playwright/test';

test.describe('Admin Dashboard', () => {
  test('displays client list', async ({ page }) => {
    await page.goto('/admin/clients');
    
    // Should see clients table
    await expect(page.locator('table')).toBeVisible();
    
    // Search should work
    await page.fill('[placeholder*="Search"]', 'John');
    await page.keyboard.press('Enter');
    
    // Results should filter
    await expect(page.locator('table tbody tr')).toHaveCount(1);
  });

  test('can change tax return status', async ({ page }) => {
    await page.goto('/admin/returns');
    
    // Click on first return
    await page.click('table tbody tr:first-child');
    
    // Change status
    await page.selectOption('[name="status"]', 'in_preparation');
    
    // Verify change saved
    await expect(page.locator('text=Status updated')).toBeVisible();
  });
});
```

### Mobile Testing

```typescript
// frontend/e2e/mobile.spec.ts
import { test, expect, devices } from '@playwright/test';

test.use(devices['iPhone 13']);

test('mobile navigation works', async ({ page }) => {
  await page.goto('/');
  
  // Hamburger menu should be visible on mobile
  await expect(page.locator('[aria-label="Menu"]')).toBeVisible();
  
  // Click menu
  await page.click('[aria-label="Menu"]');
  
  // Navigation links should appear
  await expect(page.locator('text=About')).toBeVisible();
});
```

---

## 7. Running Tests

### All Test Commands (Quick Reference)

```bash
# === Frontend Unit Tests (Vitest) ===
npm test                    # Run unit tests once
npm run test:watch          # Watch mode (re-run on changes)
npm run test:coverage       # With coverage report

# === Frontend E2E Tests (Playwright) ===
npm run test:e2e            # Run all E2E tests
npm run test:e2e:ui         # Visual test runner
npm run test:e2e:headed     # See browser during tests
npm run test:e2e:debug      # Step-through debugging
npm run test:e2e:public     # Public pages only (no auth)

# === Backend Unit Tests (RSpec) ===
cd backend
bundle exec rspec           # Run all specs
bundle exec rspec spec/models/client_spec.rb  # Specific file
```

### Playwright-Specific Commands

```bash
# Run specific test file
npx playwright test intake-form.spec.ts

# Run tests matching name
npx playwright test -g "intake"

# Update snapshots
npx playwright test --update-snapshots

# Generate HTML report
npx playwright show-report
```

### Agent Browser Commands

```bash
# Start your dev server first
npm run dev

# Then in another terminal:
agent-browser open http://localhost:5173
agent-browser snapshot -i
agent-browser click @e1
```

### CI Integration (GitHub Actions)

```yaml
# .github/workflows/test.yml
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          
      - name: Install dependencies
        run: |
          cd frontend
          npm ci
          
      - name: Install Playwright browsers
        run: |
          cd frontend
          npx playwright install --with-deps
          
      - name: Start backend
        run: |
          cd backend
          bundle install
          rails db:setup
          rails server &
        env:
          RAILS_ENV: test
          
      - name: Run Playwright tests
        run: |
          cd frontend
          npm test
        env:
          TEST_USER_EMAIL: ${{ secrets.TEST_USER_EMAIL }}
          TEST_USER_PASSWORD: ${{ secrets.TEST_USER_PASSWORD }}
          
      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: frontend/playwright-report/
```

---

## 8. AI-Assisted Testing Workflow

### After Making a Change

When the AI makes a code change, it should verify it works:

```markdown
## AI Testing Checklist

After modifying frontend code:
1. Ensure dev server is running (`npm run dev`)
2. Navigate to the affected page
3. Verify the change works:
   - `agent-browser open http://localhost:5173/affected-page`
   - `agent-browser snapshot -i` - check structure
   - Interact with changed elements
   - `agent-browser screenshot` if visual verification needed
4. Report findings to user
```

### Example AI Verification Session

```bash
# AI modifies the intake form, then verifies:

$ agent-browser open http://localhost:5173/intake
# ✓ Navigated to intake form

$ agent-browser snapshot -i
# - heading "Client Information" [ref=e1]
# - textbox "First Name" [ref=e2]
# - textbox "Last Name" [ref=e3]
# - button "Next" [ref=e4]

$ agent-browser fill @e2 "Test"
# ✓ Filled "Test" into First Name

$ agent-browser fill @e3 "User"
# ✓ Filled "User" into Last Name

$ agent-browser click @e4
# ✓ Clicked Next button

$ agent-browser snapshot -i
# - heading "Tax Filing Information" [ref=e1]
# ✓ Form advanced to step 2 - change verified!
```

### Cursor Rules for AI Testing

Add to `.cursor/rules/project.mdc`:

```markdown
## Testing After Changes

When modifying frontend code:
1. If dev server is running, use agent-browser to verify
2. Navigate to affected page
3. Test the specific change
4. Report what was tested and results

When modifying backend code:
1. Use `rails runner` or curl to test endpoint
2. Verify response matches expectations

Before marking a task complete:
1. Verify the change works (browser or API test)
2. Note what was tested in your response
```

---

## 9. Integration with Planning

### PRD Testing Section

Add to your PRD template:

```markdown
## Testing Requirements

### Critical User Flows (E2E Coverage)

| Flow | Priority | Test File |
|------|----------|-----------|
| Client intake form (complete) | P0 | `intake-form.spec.ts` |
| Admin login → dashboard | P0 | `auth.spec.ts` |
| Status change workflow | P1 | `workflow.spec.ts` |
| Document upload | P1 | `documents.spec.ts` |

### Test Accounts

| Email | Role | Purpose |
|-------|------|---------|
| test-admin@example.com | Admin | Full access testing |
| test-employee@example.com | Employee | Role-based testing |
| test-client@example.com | Client | Portal testing |

### Test Data Requirements

- [ ] Seed 5 test clients with varied data
- [ ] Seed sample documents for upload tests
- [ ] Seed all workflow stages
```

### BUILD_PLAN Testing Tasks

Add testing tasks to each phase:

```markdown
## Phase 3: Intake Form

### 3.1 Build
- [ ] Create form wizard
- [ ] Implement validation
- [ ] Add kiosk mode

### 3.2 Testing
- [ ] E2E: Complete form submission
- [ ] E2E: Validation error display
- [ ] E2E: Kiosk mode functionality
- [ ] AI: Mobile layout verification
- [ ] AI: Touch target sizes (44px+)
```

### Test Checklist Template

```markdown
## Pre-Deploy Test Checklist

### E2E Tests (Automated)
- [ ] `npm test` passes
- [ ] All critical flows green

### AI Verification
- [ ] Intake form works on mobile
- [ ] Admin dashboard loads
- [ ] Login/logout works

### Manual QA
- [ ] Stakeholder review
- [ ] Edge cases tested
- [ ] Performance acceptable
```

---

## 10. Common Patterns

### Wait for Network Idle

```typescript
// Wait for all network requests to complete
await page.waitForLoadState('networkidle');
```

### Wait for API Response

```typescript
// Wait for specific API call
const responsePromise = page.waitForResponse('**/api/v1/clients');
await page.click('button:has-text("Load Clients")');
await responsePromise;
```

### Handle Modals

```typescript
// Wait for modal to appear
await page.click('button:has-text("Open Modal")');
await page.waitForSelector('[role="dialog"]');

// Interact with modal content
await page.fill('[role="dialog"] input', 'value');
await page.click('[role="dialog"] button:has-text("Save")');

// Wait for modal to close
await expect(page.locator('[role="dialog"]')).not.toBeVisible();
```

### Handle Toasts/Notifications

```typescript
// Wait for success toast
await expect(page.locator('.toast-success')).toBeVisible();
await expect(page.locator('.toast-success')).toContainText('Saved');
```

### File Upload

```typescript
// Upload a file
await page.setInputFiles('input[type="file"]', 'path/to/test-file.pdf');

// Verify upload succeeded
await expect(page.locator('text=test-file.pdf')).toBeVisible();
```

### Drag and Drop (Kanban)

```typescript
// Drag card to new column
const card = page.locator('.kanban-card:has-text("John Doe")');
const targetColumn = page.locator('.kanban-column:has-text("In Review")');
await card.dragTo(targetColumn);
```

---

## 11. Troubleshooting

### Tests Flaky/Failing Intermittently

**Cause:** Race conditions, timing issues

**Fix:**
```typescript
// Bad - might click before element ready
await page.click('button');

// Good - wait for element
await page.waitForSelector('button:has-text("Submit")');
await page.click('button:has-text("Submit")');

// Better - use locator with auto-wait
await page.locator('button:has-text("Submit")').click();
```

### Auth State Not Persisting

**Cause:** Storage state not saved correctly

**Fix:**
1. Check `playwright/.auth/` exists
2. Verify setup test runs first (`dependencies: ['setup']`)
3. Check `.gitignore` isn't blocking auth folder creation

### Clerk Auth Test Redirects to Google OAuth

**Cause:** Navigating directly to a protected route (e.g., `/admin`) triggers Clerk's redirect flow, which may auto-redirect to Google OAuth.

**Fix:**
1. **Click your app's login button** (e.g., "Staff Login") instead of navigating directly to `/admin`
2. Use specific selectors to avoid clicking "Continue with Google":
   ```typescript
   // BAD - might match "Continue with Google"
   await page.click('button:has-text("Continue")');
   
   // GOOD - excludes Google button
   await page.locator('button:has-text("Continue")').filter({ hasNotText: 'Google' }).click();
   ```
3. After login completes, **manually navigate** to the admin area by clicking "Dashboard"

### Clerk Password Field is Disabled

**Cause:** Clerk shows a disabled password field when OAuth options are available

**Fix:**
1. Wait for the password field to be enabled, not just visible:
   ```typescript
   // Wait for enabled password field
   await page.waitForSelector('input[name="password"]:not([disabled])', { timeout: 10000 });
   ```
2. Enable "Bypass Client Trust" for the test user in Clerk Dashboard → Users → Settings

### Slow Tests

**Cause:** Network waiting, too many retries

**Fix:**
```typescript
// Increase timeout for slow operations
test('slow operation', async ({ page }) => {
  test.setTimeout(60000); // 60 seconds
  
  // Or for specific action
  await page.click('button', { timeout: 10000 });
});
```

### Can't Find Elements

**Cause:** Element not visible, wrong selector

**Fix:**
```bash
# Debug with Playwright inspector
npx playwright test --debug

# Or use codegen to record selectors
npx playwright codegen http://localhost:5173
```

### Agent Browser Connection Issues

**Cause:** Daemon not running or port conflict

**Fix:**
```bash
# Kill existing daemon
agent-browser kill

# Start fresh
agent-browser open http://localhost:5173
```

---

## 12. Comprehensive User Flow Testing

### Overview

Beyond basic E2E tests, comprehensive tests exercise **full user journeys** with real data. These are designed to:

- Create actual orders (retail, Acai cakes, fundraisers)
- Process orders through complete fulfillment workflows
- Verify admin functionality works end-to-end
- Capture screenshots at each step for review

### When to Use Comprehensive Tests

| Scenario | Use? |
|----------|------|
| After major feature implementation | ✅ Yes |
| Before production deploy | ✅ Yes |
| After refactoring core flows | ✅ Yes |
| Quick bug fix | ❌ No - use regular E2E |
| Minor UI change | ❌ No - use visual tests |

### Setup

1. **Create test directory structure:**

```
frontend/e2e/comprehensive/
├── retail-order-flow.spec.ts    # Full retail purchase + fulfillment
├── acai-order-flow.spec.ts      # Acai cake ordering + pickup workflow
├── fundraiser-flow.spec.ts      # Fundraiser browsing + ordering
└── admin-fulfillment.spec.ts    # Admin order processing
```

2. **Add to Playwright config:**

```typescript
// playwright.config.ts
{
  name: 'comprehensive',
  testMatch: /comprehensive\/.*\.spec\.ts/,
  use: { 
    ...devices['Desktop Chrome'],
    storageState: 'playwright/.auth/admin.json',
    actionTimeout: 15000,
    navigationTimeout: 30000,
  },
  dependencies: ['setup'],
  fullyParallel: false, // Tests may depend on order
},
```

3. **Add NPM scripts:**

```json
{
  "scripts": {
    "test:comprehensive": "playwright test --project=comprehensive",
    "test:comprehensive:headed": "playwright test --project=comprehensive --headed"
  }
}
```

### Example: Retail Order Flow Test

```typescript
// e2e/comprehensive/retail-order-flow.spec.ts
import { test, expect } from '@playwright/test';

test.describe('Retail Order - Complete Journey', () => {
  test('Customer: Browse → Cart → Checkout', async ({ page }) => {
    // Clear cart
    await page.goto('/');
    await page.evaluate(() => localStorage.removeItem('cart'));
    
    // Browse products
    await page.goto('/products');
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'test-results/comprehensive/01-browse.png' });
    
    // Add to cart
    await page.click('a[href^="/products/"]');
    await page.waitForLoadState('networkidle');
    await page.click('button:has-text("Add to Cart")');
    await page.screenshot({ path: 'test-results/comprehensive/02-cart.png' });
    
    // Checkout
    await page.click('button:has-text("Checkout")');
    await page.waitForLoadState('networkidle');
    await page.fill('input[name="email"]', 'test@example.com');
    await page.fill('input[name="name"]', 'Test Customer');
    // ... fill shipping, payment
    await page.screenshot({ path: 'test-results/comprehensive/03-checkout.png' });
    
    // Submit (with Stripe test card)
    await page.click('button:has-text("Place Order")');
    await page.waitForTimeout(5000);
    await page.screenshot({ path: 'test-results/comprehensive/04-confirmation.png' });
  });

  test('Admin: View and process order', async ({ page }) => {
    await page.goto('/admin/orders');
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'test-results/comprehensive/05-admin-orders.png' });
    
    // View order
    await page.click('button:has-text("View Details")');
    await page.screenshot({ path: 'test-results/comprehensive/06-order-detail.png' });
    
    // Change status
    await page.click('button:has-text("Start Processing")');
    await page.waitForTimeout(1000);
    await page.screenshot({ path: 'test-results/comprehensive/07-processing.png' });
  });
});
```

### Running Comprehensive Tests

```bash
# Run all comprehensive tests
npm run test:comprehensive

# Watch the browser (great for debugging)
npm run test:comprehensive:headed

# Run specific flow
npx playwright test e2e/comprehensive/acai-order-flow.spec.ts
```

### What Gets Created

Running comprehensive tests will:

1. **Create real orders** in your database
2. **Send emails** (if email is enabled)
3. **Save screenshots** to `test-results/comprehensive/`
4. **Change order statuses** during fulfillment tests

### Cleanup (Optional)

After running comprehensive tests, you may want to clean up test data:

```bash
# In Rails console
rails runner "
  Order.where('email LIKE ?', '%@example.com').destroy_all
  puts 'Test orders cleaned up'
"
```

### Best Practices

1. **Run on test data** - Use a local dev database, not production
2. **Use Stripe test mode** - Test card: 4242 4242 4242 4242
3. **Review screenshots** - Check `test-results/comprehensive/` after each run
4. **Run before major deploys** - Catch integration issues early
5. **Don't run in CI by default** - These create real data

### Integration with AI Testing

When the AI performs comprehensive testing, it should:

1. **Run the tests** with `npm run test:comprehensive`
2. **Review screenshots** in `test-results/comprehensive/`
3. **Report any failures** with the relevant screenshot
4. **Verify database state** with `rails runner` commands

---

## Mandatory Verification Before "Done"

### For Any New Page/Feature

1. **Actually open the page** in a browser (or use agent-browser)
2. **Check the browser console** for JavaScript errors
3. **Check the Network tab** for failed API calls (4xx, 5xx errors)
4. **Check backend logs** for routing errors or exceptions

### For New API Service Files

Before creating a new API service file:

1. **Check the axios base URL** in `api.ts` - don't duplicate path prefixes
2. **Review 2-3 existing service files** for URL pattern conventions
3. **Test the actual page** that uses the service - verify API calls succeed

| Common Mistake | Symptom | Prevention |
|----------------|---------|------------|
| Doubled URL prefix | 404 errors, "No route matches" | Check baseURL in api.ts |
| Missing auth header | 401 Unauthorized | Check how other services pass auth |
| Wrong HTTP method | 404 or 405 errors | Verify against backend routes |

### New API Service Checklist

- [ ] Checked `api.ts` base URL configuration
- [ ] Reviewed existing service files for URL patterns
- [ ] Navigated to page using the service
- [ ] Verified API calls succeed (no 404s in Network tab)
- [ ] Checked backend logs for routing errors

---

## Quick Reference

### Agent Browser Commands

```bash
agent-browser open <url>           # Navigate
agent-browser snapshot -i          # Get elements with refs
agent-browser snapshot -i --json   # JSON output for AI
agent-browser click @e1            # Click element
agent-browser fill @e1 "text"      # Type text
agent-browser screenshot           # Capture screen
agent-browser --headed open <url>  # Show browser window
```

### Playwright Commands

```bash
npm test                    # Vitest (unit tests)
npm run test:e2e            # Playwright (E2E tests)
npm run test:e2e:headed     # See browser during E2E
npx playwright codegen     # Record test
npx playwright show-report # View results
```

### Checklist

```
Initial Setup:
□ agent-browser installed globally
□ Playwright installed in frontend
□ Test account created in Clerk
□ "Bypass Client Trust" enabled for test user
□ .env with test credentials (gitignored)
□ Auth setup test written
□ playwright.config.ts configured

Per Feature (AI should do all of these):
□ Feature code implemented
□ Backend API tested with curl
□ Comprehensive E2E test created/updated
□ Happy path tested
□ Error/validation cases tested
□ Mobile tested if applicable
□ All tests pass
□ Ready for user verification
```

---

## 13. Test-Alongside Development

### The Principle

**When building features, create or update tests at the same time - not as an afterthought.**

This ensures:
- Features are verified before the user tests them
- Regression tests exist from day one
- AI can verify its own work
- Test coverage grows with the codebase

### The Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. IMPLEMENT                                                │
│     Write the feature code (backend + frontend)              │
│                           ↓                                  │
│  2. CREATE/UPDATE TESTS                                      │
│     Add comprehensive tests for the new functionality        │
│                           ↓                                  │
│  3. RUN TESTS                                                │
│     Execute tests to verify everything works                 │
│                           ↓                                  │
│  4. REPORT TO USER                                           │
│     "Feature implemented and tested. Ready for verification."│
└─────────────────────────────────────────────────────────────┘
```

### When to Create New Tests

| You're Building... | Create This Test |
|--------------------|------------------|
| New customer-facing feature | `e2e/comprehensive/[feature].spec.ts` |
| New order type | `e2e/comprehensive/[order-type]-order-flow.spec.ts` |
| New admin functionality | Add to `admin-fulfillment.spec.ts` or create new |
| New API endpoint | Verify with `curl`, consider E2E test |
| Bug fix | Add test that would have caught the bug |

### When to Update Existing Tests

| You Changed... | Update This |
|----------------|-------------|
| UI element selectors | Test selectors (classes, text, data-testid) |
| User flow steps | Test steps to match new flow |
| Form fields | Add assertions for new fields |
| Removed functionality | Remove or skip related tests |
| Page URLs | Update `page.goto()` calls |

### Example: Building a Wishlist Feature

```typescript
// User asks: "Add a wishlist feature"

// AI implements the feature, then creates:
// e2e/comprehensive/wishlist.spec.ts

import { test, expect } from '@playwright/test';

test.describe('Wishlist Feature', () => {
  test.use({ storageState: 'playwright/.auth/admin.json' });

  test('Add product to wishlist', async ({ page }) => {
    await page.goto('/products');
    await page.locator('a[href^="/products/"]').first().click();
    await page.locator('button:has-text("Add to Wishlist")').click();
    await expect(page.locator('text=Added to wishlist')).toBeVisible();
  });

  test('View wishlist', async ({ page }) => {
    await page.goto('/account/wishlist');
    await expect(page.locator('[class*="wishlist-item"]')).toHaveCount.greaterThan(0);
  });

  test('Remove from wishlist', async ({ page }) => {
    await page.goto('/account/wishlist');
    await page.locator('button:has-text("Remove")').first().click();
    await expect(page.locator('text=Removed from wishlist')).toBeVisible();
  });

  test('Move wishlist item to cart', async ({ page }) => {
    await page.goto('/account/wishlist');
    await page.locator('button:has-text("Add to Cart")').first().click();
    await expect(page.locator('[class*="cart"]')).toContainText('1');
  });
});
```

### Test File Organization

Keep comprehensive tests organized by feature area:

```
e2e/comprehensive/
├── retail-order-flow.spec.ts    # Retail purchase journey
├── acai-order-flow.spec.ts      # Acai cake ordering
├── fundraiser-flow.spec.ts      # Fundraiser ordering
├── admin-fulfillment.spec.ts    # Admin order management
├── customer-account.spec.ts     # Customer account features
├── mobile-admin.spec.ts         # Mobile admin flows
├── inventory-stock.spec.ts      # Stock management
├── wishlist.spec.ts             # ← New feature test
└── [new-feature].spec.ts        # Add new features here
```

### AI Checklist for Each Feature

Before reporting a feature as "done", the AI should:

```
□ Feature code implemented
□ Backend API tested with curl (if applicable)
□ Frontend UI verified with Playwright
□ New/updated comprehensive test created
□ Tests pass when run
□ Screenshots captured for complex flows
□ Edge cases considered (empty states, errors, mobile)
```

### Practical Tips (Lessons Learned)

**Running Tests Efficiently:**
```bash
# Run tests in batches - full suite can timeout
npx playwright test --grep="View orders|View products" --project=comprehensive

# Use dot reporter for long runs
npx playwright test --reporter=dot --retries=0

# Run specific file only
npx playwright test e2e/comprehensive/fundraiser-flow.spec.ts
```

**Debugging Failing Tests:**
1. Check screenshots first - `test-results/` contains failure images
2. Read the selector in error message - shows exactly what wasn't found
3. Compare to actual UI - inspect the real element placeholders/classes
4. Use flexible selectors - `input[placeholder*="email" i]` over `input[name="email"]`

**Making Tests Resilient:**
```typescript
// Check if element exists before interacting
const submitButton = page.locator('button:has-text("Submit")');
if (await submitButton.isVisible()) {
  if (await submitButton.isEnabled()) {
    await submitButton.click();
  } else {
    console.log('Submit disabled - form incomplete');
  }
}
```

**Selector Best Practices:**
| Instead of... | Use... |
|---------------|--------|
| `input[name="email"]` | `input[placeholder*="email" i]` |
| `.product-card` | `a[href^="/products/"]` |
| `#submit-btn` | `button:has-text("Submit")` |

**When Form Submit is Disabled:**
- Don't force click - the form validation isn't complete
- Take a screenshot to document the state
- Log what's happening for debugging
- Consider it a partial success (UI loads, just can't complete full flow)

### Benefits

1. **Catch bugs early** - AI finds issues before user tests
2. **Regression prevention** - Future changes won't break existing features
3. **Documentation** - Tests show how features should work
4. **Confidence** - Know the feature actually works, not just compiles
5. **Faster iteration** - Less back-and-forth between AI and user

---

## 14. Common Bugs & How to Prevent Them

Document project-specific bugs here so they don't repeat. Each entry should include what went wrong, how it was caught, and how to prevent it.

### Template Entry

**Bug:** [Brief description]

**What happened:** [Details]

**How it was caught:** [How the issue was discovered]

**Prevention checklist:**
- [ ] Step 1
- [ ] Step 2
- [ ] Step 3

### Example: Doubled API URL Prefix

**Bug:** API service used full URL path when axios base already included prefix

**What happened:** Created a service file with URLs like `/api/v1/admin/resource`, but the axios base URL already included `/api/v1`. Result: requests went to `/api/v1/api/v1/admin/resource` causing 404 errors.

**How it was caught:** User saw `ActionController::RoutingError` in Rails logs.

**Prevention checklist:**
- [ ] Before creating new API service files, check `api.ts` for base URL configuration
- [ ] Review 2-3 existing service files to see URL patterns
- [ ] Navigate to the page and verify API calls succeed (check Network tab)
- [ ] Check backend logs for routing errors after implementing

---

*Last updated: January 2026*
