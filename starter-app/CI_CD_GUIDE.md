# CI/CD Guide (GitHub Actions)

A comprehensive guide for setting up continuous integration and deployment for Rails + React apps using GitHub Actions. Covers testing, auto-deployment to Render and Netlify, branch protection, and CodeRabbit integration.

---

## Table of Contents
1. [Overview](#1-overview)
2. [Workflow File Structure](#2-workflow-file-structure)
3. [Rails CI: RSpec + PostgreSQL](#3-rails-ci-rspec--postgresql)
4. [React CI: TypeScript + Build + Tests](#4-react-ci-typescript--build--tests)
5. [Auto-Deploy: Render](#5-auto-deploy-render)
6. [Auto-Deploy: Netlify](#6-auto-deploy-netlify)
7. [Branch Protection Rules](#7-branch-protection-rules)
8. [Environment Secrets Management](#8-environment-secrets-management)
9. [Matrix Testing](#9-matrix-testing)
10. [CodeRabbit Integration](#10-coderabbit-integration)
11. [PR Status Checks](#11-pr-status-checks)
12. [Advanced Patterns](#12-advanced-patterns)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Overview

### The CI/CD Pipeline

```
  Developer pushes code
         │
         ▼
  ┌─────────────────┐
  │  GitHub Actions  │
  │                  │
  │  ┌────────────┐  │     ┌─────────────┐
  │  │ Rails CI   │──│────▶│  RSpec       │
  │  │ (Backend)  │  │     │  Rubocop     │
  │  └────────────┘  │     │  Brakeman    │
  │                  │     └─────────────┘
  │  ┌────────────┐  │     ┌─────────────┐
  │  │ React CI   │──│────▶│  TypeScript  │
  │  │ (Frontend) │  │     │  Build       │
  │  └────────────┘  │     │  Playwright  │
  └──────┬───────────┘     └─────────────┘
         │
         │ All checks pass + merge to main
         ▼
  ┌─────────────────┐     ┌─────────────────┐
  │  Render          │     │  Netlify         │
  │  (Auto-deploy    │     │  (Auto-deploy    │
  │   backend)       │     │   frontend)      │
  └─────────────────┘     └─────────────────┘
```

### The Shimizu Way

> **CI should be fast and reliable.** A CI pipeline that takes 20 minutes or flakes 10% of the time is worse than no CI. Target: **Rails CI < 5 minutes, React CI < 3 minutes.** If your pipeline is slow, fix it before adding more tests.

---

## 2. Workflow File Structure

### Directory Layout

```
.github/
└── workflows/
    ├── ci-backend.yml       # Rails: RSpec, Rubocop, Brakeman
    ├── ci-frontend.yml      # React: TypeScript, build, Playwright
    ├── deploy-backend.yml   # Auto-deploy Rails to Render
    └── deploy-frontend.yml  # (Optional — Netlify auto-deploys)
```

### When to Use Separate vs Combined Workflows

| Approach | When to Use |
|----------|-------------|
| **Separate workflows** (recommended) | Frontend and backend are in separate repos |
| **Combined workflow** | Monorepo with both frontend and backend |
| **Monorepo with path filters** | Monorepo where you only want to run affected CI |

---

## 3. Rails CI: RSpec + PostgreSQL

### 3.1 Basic Rails CI Workflow

```yaml
# .github/workflows/ci-backend.yml
name: Rails CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: RSpec Tests
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: myapp_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test
      CLERK_SECRET_KEY: test_clerk_secret

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true

      - name: Setup database
        run: |
          bundle exec rails db:create
          bundle exec rails db:schema:load

      - name: Run RSpec
        run: bundle exec rspec --format documentation --format RspecJunitFormatter --out tmp/rspec-results.xml

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: rspec-results
          path: tmp/rspec-results.xml

  lint:
    name: Rubocop
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true

      - name: Run Rubocop
        run: bundle exec rubocop --parallel

  security:
    name: Security Scan
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true

      - name: Run Brakeman
        run: bundle exec brakeman --no-pager --format json --output tmp/brakeman-results.json || true

      - name: Upload Brakeman results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: brakeman-results
          path: tmp/brakeman-results.json
```

### 3.2 Required Gems for CI

```ruby
# Gemfile
group :test do
  gem 'rspec-rails', '~> 6.0'
  gem 'factory_bot_rails'
  gem 'faker'
  gem 'shoulda-matchers'
  gem 'rspec_junit_formatter'  # For CI test result reporting
end

group :development, :test do
  gem 'rubocop', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-rspec', require: false
  gem 'brakeman', require: false
end
```

### 3.3 Adding Redis (for ActionCable/Sidekiq Tests)

```yaml
# Add to the services section
services:
  postgres:
    # ... (same as above)

  redis:
    image: redis:7
    ports:
      - 6379:6379
    options: >-
      --health-cmd "redis-cli ping"
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5

env:
  REDIS_URL: redis://localhost:6379/0
```

---

## 4. React CI: TypeScript + Build + Tests

### 4.1 Basic React CI Workflow

```yaml
# .github/workflows/ci-frontend.yml
name: React CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  typecheck:
    name: TypeScript Check
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: TypeScript check
        run: npx tsc --noEmit

  build:
    name: Production Build
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build
        env:
          VITE_API_URL: https://api.example.com
          VITE_CLERK_PUBLISHABLE_KEY: pk_test_placeholder

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: build-output
          path: dist/

  lint:
    name: ESLint
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run ESLint
        run: npx eslint . --max-warnings 0

  e2e:
    name: Playwright E2E Tests
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    needs: [typecheck, build]

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Install Playwright browsers
        run: npx playwright install --with-deps chromium

      - name: Run Playwright tests
        run: npx playwright test
        env:
          VITE_API_URL: https://api-staging.example.com

      - name: Upload Playwright report
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report
          path: playwright-report/
```

### 4.2 Monorepo Workflow

If frontend and backend are in the same repo:

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  detect-changes:
    name: Detect Changes
    runs-on: ubuntu-latest
    outputs:
      backend: ${{ steps.changes.outputs.backend }}
      frontend: ${{ steps.changes.outputs.frontend }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: changes
        with:
          filters: |
            backend:
              - 'backend/**'
              - 'Gemfile*'
            frontend:
              - 'frontend/**'
              - 'package*.json'

  backend:
    name: Rails Tests
    runs-on: ubuntu-latest
    needs: detect-changes
    if: needs.detect-changes.outputs.backend == 'true'
    defaults:
      run:
        working-directory: backend
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: myapp_test
        ports:
          - 5432:5432
        options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
          working-directory: backend
      - run: bundle exec rails db:create db:schema:load
      - run: bundle exec rspec

  frontend:
    name: React Build
    runs-on: ubuntu-latest
    needs: detect-changes
    if: needs.detect-changes.outputs.frontend == 'true'
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: frontend/package-lock.json
      - run: npm ci
      - run: npx tsc --noEmit
      - run: npm run build
```

---

## 5. Auto-Deploy: Render

### 5.1 Deploy Hook Method (Simple)

Render provides a deploy hook URL — hit it to trigger a deploy:

```yaml
# .github/workflows/deploy-backend.yml
name: Deploy Backend

on:
  push:
    branches: [main]

jobs:
  deploy:
    name: Deploy to Render
    runs-on: ubuntu-latest
    # Only deploy if CI passes
    needs: [test, lint]  # Reference your CI job names

    steps:
      - name: Trigger Render Deploy
        run: |
          curl -X POST "${{ secrets.RENDER_DEPLOY_HOOK_URL }}"
```

### 5.2 Get Your Deploy Hook URL

1. Go to Render Dashboard → Your Web Service
2. **Settings** → **Deploy Hook**
3. Copy the URL (looks like `https://api.render.com/deploy/srv-xxx?key=yyy`)
4. Add it as a GitHub secret: `RENDER_DEPLOY_HOOK_URL`

### 5.3 Render Auto-Deploy (Alternative)

Render can auto-deploy on push to main without GitHub Actions:

1. Render Dashboard → Your Web Service → **Settings**
2. **Build & Deploy** → **Auto-Deploy** → **Yes**
3. Select the branch: `main`

> **When to use deploy hooks vs auto-deploy:**
> - **Auto-deploy:** Simpler, but deploys even if CI fails
> - **Deploy hooks in Actions:** Only deploys after CI passes (recommended)

### 5.4 Render Blueprint (render.yaml)

```yaml
# render.yaml
services:
  - type: web
    name: myapp-api
    runtime: ruby
    plan: starter
    repo: https://github.com/shimizu-technology/myapp-backend
    branch: main
    buildCommand: |
      bundle install
      bundle exec rails db:migrate
    startCommand: bundle exec puma -C config/puma.rb
    healthCheckPath: /up
    autoDeploy: false  # We use deploy hooks instead
    envVars:
      - key: RAILS_ENV
        value: production
      - key: RAILS_MASTER_KEY
        sync: false  # Set manually in Render UI
      - key: DATABASE_URL
        fromDatabase:
          name: myapp-db
          property: connectionString
```

---

## 6. Auto-Deploy: Netlify

### 6.1 Built-In Auto-Deploy

Netlify auto-deploys on every push — no GitHub Actions needed. Just connect your repo.

### 6.2 Netlify Configuration

```toml
# netlify.toml
[build]
  command = "npm run build"
  publish = "dist"

[build.environment]
  NODE_VERSION = "20"
  VITE_API_URL = "https://api.myapp.com"

# Deploy previews for every PR
[context.deploy-preview]
  command = "npm run build"

[context.deploy-preview.environment]
  VITE_API_URL = "https://api-staging.myapp.com"

# Branch deploys
[context.branch-deploy]
  command = "npm run build"

# Production
[context.production]
  command = "npm run build"

[context.production.environment]
  VITE_API_URL = "https://api.myapp.com"

# Redirect all routes to index.html (SPA)
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

### 6.3 Environment Variables in Netlify

Set environment variables in **Netlify Dashboard** → **Site settings** → **Environment variables**:

| Variable | Value | Notes |
|----------|-------|-------|
| `VITE_API_URL` | `https://api.myapp.com` | Backend API URL |
| `VITE_CLERK_PUBLISHABLE_KEY` | `pk_live_xxx` | Clerk auth |
| `VITE_SENTRY_DSN` | `https://xxx@sentry.io/yyy` | Error tracking |
| `SENTRY_AUTH_TOKEN` | `sntrys_xxx` | For source map uploads |

### 6.4 Deploy Previews

Every PR automatically gets a deploy preview URL:
- `https://deploy-preview-42--myapp.netlify.app`

This is incredibly useful for QA:
1. Open the deploy preview
2. Test the changes in a real environment
3. Approve the PR

### 6.5 Netlify Build Notifications in GitHub Actions (Optional)

```yaml
# If you want to notify about Netlify deploys in your workflow
- name: Wait for Netlify deploy
  uses: probablyup/wait-for-netlify-action@v3
  with:
    site_id: ${{ secrets.NETLIFY_SITE_ID }}
  env:
    NETLIFY_TOKEN: ${{ secrets.NETLIFY_AUTH_TOKEN }}
```

---

## 7. Branch Protection Rules

### 7.1 Recommended Rules for `main`

Go to **GitHub** → **Settings** → **Branches** → **Add rule** for `main`:

| Setting | Value | Why |
|---------|-------|-----|
| **Require a pull request before merging** | ✅ On | No direct pushes to main |
| **Require approvals** | 1 (or 0 for solo projects) | Code review |
| **Dismiss stale reviews** | ✅ On | Re-review after changes |
| **Require status checks to pass** | ✅ On | CI must pass |
| **Required checks** | `RSpec Tests`, `TypeScript Check`, `Production Build` | Specific jobs |
| **Require branches to be up to date** | ✅ On | No merge conflicts |
| **Require linear history** | Optional | Cleaner git history |
| **Include administrators** | ✅ On | Rules apply to everyone |

### 7.2 Setting Required Status Checks

After your first CI run, GitHub knows which checks exist. Then:

1. Go to **Settings** → **Branches** → **Edit rule**
2. Under **Require status checks**, search for your job names:
   - `RSpec Tests`
   - `Rubocop`
   - `TypeScript Check`
   - `Production Build`
3. Check each one you want to require

### 7.3 For Solo Projects

Even for solo projects, branch protection is valuable:

```
✅ Require status checks to pass
✅ Require branches to be up to date
❌ Require approvals (skip — you're the only reviewer)
✅ Include administrators
```

---

## 8. Environment Secrets Management

### 8.1 GitHub Secrets

Store secrets in GitHub → **Settings** → **Secrets and variables** → **Actions**:

| Secret | Purpose | Used By |
|--------|---------|---------|
| `RENDER_DEPLOY_HOOK_URL` | Trigger backend deploys | deploy-backend.yml |
| `SENTRY_AUTH_TOKEN` | Upload source maps | ci-frontend.yml |
| `VITE_SENTRY_DSN` | Frontend error tracking | ci-frontend.yml |
| `CLERK_SECRET_KEY` | Test authentication | ci-backend.yml |
| `RAILS_MASTER_KEY` | Decrypt Rails credentials | ci-backend.yml |

### 8.2 Using Secrets in Workflows

```yaml
steps:
  - name: Deploy
    env:
      RENDER_DEPLOY_HOOK: ${{ secrets.RENDER_DEPLOY_HOOK_URL }}
    run: curl -X POST "$RENDER_DEPLOY_HOOK"
```

### 8.3 Environment-Specific Secrets

GitHub supports **Environments** for different configs:

```yaml
# .github/workflows/deploy.yml
jobs:
  deploy-staging:
    environment: staging
    steps:
      - name: Deploy to staging
        env:
          DEPLOY_URL: ${{ secrets.STAGING_DEPLOY_HOOK }}
        run: curl -X POST "$DEPLOY_URL"

  deploy-production:
    environment: production
    needs: [deploy-staging]
    steps:
      - name: Deploy to production
        env:
          DEPLOY_URL: ${{ secrets.PRODUCTION_DEPLOY_HOOK }}
        run: curl -X POST "$DEPLOY_URL"
```

### 8.4 Never Commit Secrets

```gitignore
# .gitignore
.env
.env.local
.env.production.local
config/master.key
config/credentials/*.key
```

---

## 9. Matrix Testing

### 9.1 Test Multiple Ruby Versions

```yaml
jobs:
  test:
    name: RSpec (Ruby ${{ matrix.ruby-version }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby-version: ['3.2', '3.3']

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: myapp_test
        ports:
          - 5432:5432
        options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5

    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test

    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby-version }}
          bundler-cache: true
      - run: bundle exec rails db:create db:schema:load
      - run: bundle exec rspec
```

### 9.2 Test Multiple Node Versions

```yaml
jobs:
  build:
    name: Build (Node ${{ matrix.node-version }})
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: ['18', '20', '22']

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
          cache: 'npm'
      - run: npm ci
      - run: npm run build
```

### 9.3 When to Use Matrix Testing

| Scenario | Use Matrix? | Why |
|----------|-------------|-----|
| Library/gem (multiple consumers) | ✅ Yes | Ensure compatibility |
| Production app (single version) | ❌ No | Waste of CI minutes |
| Upgrading Ruby/Node | ✅ Temporarily | Verify both versions work |
| Open source project | ✅ Yes | Support multiple versions |

> **The Shimizu Way:** For production apps, test the version you deploy. Matrix testing is for libraries and upgrade migrations.

---

## 10. CodeRabbit Integration

### 10.1 What is CodeRabbit?

CodeRabbit is an AI-powered code reviewer that automatically reviews PRs. It catches bugs, suggests improvements, and enforces patterns.

### 10.2 Setup

1. Go to [coderabbit.ai](https://coderabbit.ai)
2. Install the GitHub App on your organization
3. Configure which repos to review

### 10.3 Configuration

```yaml
# .coderabbit.yaml (in repo root)
language: en-US
reviews:
  profile: assertive
  request_changes_workflow: true
  high_level_summary: true
  poem: false
  review_status: true
  collapse_walkthrough: false
  auto_review:
    enabled: true
    drafts: false
    base_branches:
      - main
  path_filters:
    - '!**/*.md'           # Don't review markdown
    - '!**/*.lock'         # Don't review lock files
    - '!**/package-lock.json'
  path_instructions:
    - path: 'app/controllers/**'
      instructions: |
        Review for:
        - Proper authentication (before_action)
        - Correct HTTP status codes
        - Input validation
        - N+1 query prevention
    - path: 'src/**/*.tsx'
      instructions: |
        Review for:
        - TypeScript type safety (no 'any')
        - Proper error handling
        - Accessibility (aria labels, semantic HTML)
        - React hooks rules
chat:
  auto_reply: true
```

### 10.4 Working with CodeRabbit Reviews

CodeRabbit adds review comments to PRs. To interact:

```
# In a PR comment, reply to CodeRabbit:
@coderabbitai resolve    # Mark a suggestion as resolved
@coderabbitai explain    # Ask for more detail
@coderabbitai ignore     # Ignore this type of suggestion
```

### 10.5 CodeRabbit + CI Together

CodeRabbit runs alongside your CI:

```
PR Created
   │
   ├── GitHub Actions: Run tests ─────▶ ✅ Pass / ❌ Fail
   │
   ├── CodeRabbit: AI code review ────▶ 💬 Comments + suggestions
   │
   └── Netlify: Deploy preview ───────▶ 🔗 Preview URL
```

All three run in parallel, giving you fast feedback.

---

## 11. PR Status Checks

### 11.1 Understanding Status Checks

Each CI job creates a status check on the PR:

```
✅ RSpec Tests — All 42 tests passed
✅ Rubocop — No offenses detected
✅ TypeScript Check — No errors
✅ Production Build — Build successful
🔄 Playwright E2E — Running...
💬 CodeRabbit — Review in progress
🔗 Netlify — Deploy preview ready
```

### 11.2 Custom Status Badges

Add status badges to your README:

```markdown
<!-- README.md -->
![Rails CI](https://github.com/shimizu-technology/myapp-backend/actions/workflows/ci-backend.yml/badge.svg)
![React CI](https://github.com/shimizu-technology/myapp-frontend/actions/workflows/ci-frontend.yml/badge.svg)
[![Netlify Status](https://api.netlify.com/api/v1/badges/xxx/deploy-status)](https://app.netlify.com/sites/myapp/deploys)
```

### 11.3 Slack Notifications for CI

```yaml
# Add to any workflow
- name: Notify Slack on failure
  if: failure()
  uses: 8398a7/action-slack@v3
  with:
    status: ${{ job.status }}
    text: '❌ CI failed on ${{ github.ref_name }}'
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
    fields: repo,message,commit,author

- name: Notify Slack on deploy
  if: success()
  uses: 8398a7/action-slack@v3
  with:
    status: custom
    custom_payload: |
      {
        "text": "🚀 Deployed ${{ github.ref_name }} to production",
        "attachments": [{
          "color": "good",
          "fields": [
            {"title": "Commit", "value": "${{ github.event.head_commit.message }}", "short": true},
            {"title": "Author", "value": "${{ github.actor }}", "short": true}
          ]
        }]
      }
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
```

---

## 12. Advanced Patterns

### 12.1 Caching Dependencies

GitHub Actions automatically caches with `setup-ruby` and `setup-node`, but you can add custom caching:

```yaml
- name: Cache Playwright browsers
  uses: actions/cache@v4
  with:
    path: ~/.cache/ms-playwright
    key: playwright-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      playwright-${{ runner.os }}-
```

### 12.2 Parallel Test Execution

Split RSpec across multiple runners for faster CI:

```yaml
jobs:
  test:
    name: RSpec (Part ${{ matrix.ci_node_index }})
    runs-on: ubuntu-latest
    strategy:
      matrix:
        ci_node_total: [3]
        ci_node_index: [0, 1, 2]

    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true

      - name: Setup DB
        run: bundle exec rails db:create db:schema:load
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test

      - name: Run RSpec (split)
        run: |
          # Get list of test files and split by node index
          TEST_FILES=$(find spec -name '*_spec.rb' | sort | awk "NR % ${{ matrix.ci_node_total }} == ${{ matrix.ci_node_index }}")
          bundle exec rspec $TEST_FILES
```

### 12.3 Conditional Deploys

```yaml
jobs:
  deploy:
    name: Deploy
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    needs: [test, lint, build]

    steps:
      - name: Deploy to Render
        run: curl -X POST "${{ secrets.RENDER_DEPLOY_HOOK_URL }}"

      # Create a GitHub release
      - name: Create Release Tag
        run: |
          TAG="deploy-$(date +%Y%m%d-%H%M%S)"
          gh release create "$TAG" --title "Deploy $TAG" --notes "Auto-deploy from CI"
        env:
          GH_TOKEN: ${{ github.token }}
```

### 12.4 Database Seeding for E2E Tests

```yaml
e2e:
  name: E2E Tests
  runs-on: ubuntu-latest

  services:
    postgres:
      image: postgres:16
      env:
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: postgres
      ports:
        - 5432:5432

  steps:
    - uses: actions/checkout@v4

    # Start the backend
    - uses: ruby/setup-ruby@v1
      with:
        ruby-version: '3.3'
        bundler-cache: true

    - name: Setup and seed database
      run: |
        bundle exec rails db:create db:schema:load db:seed
      env:
        RAILS_ENV: test
        DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test

    - name: Start Rails server
      run: |
        bundle exec rails server -p 3000 -e test &
        sleep 5  # Wait for server to start

    # Run frontend E2E tests against the running backend
    - uses: actions/setup-node@v4
      with:
        node-version: '20'
        cache: 'npm'
    - run: npm ci
    - run: npx playwright install --with-deps chromium
    - run: npx playwright test
      env:
        VITE_API_URL: http://localhost:3000
```

---

## 13. Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| `pg_isready` fails | PostgreSQL service not ready | Increase health check retries |
| `bundle install` slow | No cache | Ensure `bundler-cache: true` in setup-ruby |
| `npm ci` fails | Lock file mismatch | Run `npm install` locally and commit `package-lock.json` |
| Tests pass locally, fail in CI | Environment differences | Check env vars, database state |
| Deploy hook returns 401 | Wrong secret | Regenerate deploy hook URL |
| Workflow doesn't trigger | Wrong branch/event | Check `on:` section carefully |
| Matrix job fails on one version | Version-specific issue | Check Ruby/Node changelogs |

### Debugging CI Failures

1. **Check the logs:** Click the failed step in GitHub Actions
2. **Run locally:** Try the exact commands from the workflow
3. **Add debugging:**

```yaml
- name: Debug info
  run: |
    ruby --version
    bundle --version
    node --version
    npm --version
    echo "DATABASE_URL: $DATABASE_URL"
    bundle exec rails db:version
```

4. **SSH into runner (for hard-to-debug issues):**

```yaml
- name: Setup SSH debug
  if: failure()
  uses: mxschmitt/action-tmate@v3
  timeout-minutes: 15
```

### Optimizing CI Speed

| Technique | Savings | How |
|-----------|---------|-----|
| **Dependency caching** | 1-3 minutes | `bundler-cache: true`, `cache: 'npm'` |
| **Parallel jobs** | 30-50% | Run lint, test, build in parallel |
| **Path filters** | Skip unnecessary runs | Only run backend CI when backend changes |
| **Selective E2E** | 2-5 minutes | Only run Playwright on PRs, not every push |
| **Test splitting** | 30-60% | Split RSpec across multiple runners |

### GitHub Actions Billing

| Plan | Minutes/Month | Notes |
|------|---------------|-------|
| Free | 2,000 | Enough for most small teams |
| Team | 3,000 | $4/user/month |
| Enterprise | 50,000 | $21/user/month |

> **The Shimizu Way:** The free tier is plenty for most projects. If you're burning through minutes, optimize CI speed before upgrading.
