# Deployment Guide (Netlify + Render + Neon)

A guide for deploying React frontends to Netlify, Rails backends to Render, and PostgreSQL databases to Neon.

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Neon Database Setup](#3-neon-database-setup)
4. [Render Backend Setup](#4-render-backend-setup)
5. [Netlify Frontend Setup](#5-netlify-frontend-setup)
6. [Custom Domain Configuration](#6-custom-domain-configuration)
7. [Environment Variables Reference](#7-environment-variables-reference)
8. [Post-Deployment Checklist](#8-post-deployment-checklist)
9. [Common Issues & Solutions](#9-common-issues--solutions)
10. [Cost Overview](#10-cost-overview)

---

## 1. Architecture Overview

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Netlify     │     │     Render      │     │      Neon       │
│   (Frontend)    │────▶│   (Backend)     │────▶│   (Database)    │
│   React/Vite    │     │   Rails API     │     │   PostgreSQL    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
   yourapp.com           api.yourapp.com          *.neon.tech
   (or Netlify URL)      (or Render URL)      (connection string)
```

### Why This Stack?

| Service | Purpose | Free Tier | Paid |
|---------|---------|-----------|------|
| **Netlify** | Frontend hosting, CDN, auto-deploy | 100 GB bandwidth/month | $19/mo |
| **Render** | Backend hosting, auto-deploy | 750 hours/month (sleeps after 15min) | $7/mo |
| **Neon** | Serverless PostgreSQL | 0.5 GB storage, 190 hours compute/month | $19/mo |

> ⚠️ **Important: Free tier is for demos and student projects ONLY.** For any client-facing or production application, always use at least Render's $7/month tier. The free tier sleeps after 15 minutes of inactivity, causing 30+ second cold starts — unacceptable for real users. A customer trying to place an order or load your app shouldn't wait half a minute.

### Alternatives

| Component | Alternative | Notes |
|-----------|-------------|-------|
| Netlify | Vercel, Cloudflare Pages | Similar features, Vercel has better Next.js support |
| Render | Railway, Fly.io, Heroku | Railway = simpler, Fly.io = more control |
| Neon | Supabase, PlanetScale, Railway Postgres | Supabase = more features, PlanetScale = MySQL |

---

## 2. Prerequisites

### Required Accounts
- [ ] GitHub account (for auto-deploy)
- [ ] Netlify account ([netlify.com](https://netlify.com))
- [ ] Render account ([render.com](https://render.com))
- [ ] Neon account ([neon.tech](https://neon.tech))

### Project Requirements
- [ ] Code pushed to GitHub repository
- [ ] Frontend and backend in separate directories (or separate repos)
- [ ] Rails configured for PostgreSQL
- [ ] `.gitignore` properly configured (no `.env`, `node_modules`, etc.)

### Local Testing
Before deploying, verify everything works locally:
```bash
# Backend
cd backend
bundle install
rails db:create db:migrate db:seed
rails server

# Frontend (new terminal)
cd frontend
npm install
npm run dev
```

---

## 3. Neon Database Setup

### 3.1 Create Project

1. Go to [neon.tech](https://neon.tech) and sign in
2. Click **Create Project**
3. Configure:
   - **Project name**: `myapp-production`
   - **Postgres version**: Latest (15 or 16)
   - **Region**: Choose closest to your users (or Render region)
   
   | Region | Best For |
   |--------|----------|
   | US East (Ohio) | US East Coast users |
   | US West (Oregon) | US West Coast users |
   | EU (Frankfurt) | European users |
   | Asia Pacific (Singapore) | Asia/Pacific users |

4. Click **Create Project**

### 3.2 Get Connection String

After creation, you'll see the connection details:

```
postgresql://username:password@ep-xxx-yyy.region.aws.neon.tech/neondb?sslmode=require
```

**Copy this string** - you'll need it for Render.

### 3.3 Create Production Database

By default, Neon creates a database called `neondb`. You can rename it or create a new one:

1. Go to **Databases** in the sidebar
2. Click **New Database**
3. Name it (e.g., `myapp_production`)
4. Update your connection string to use the new database name

### 3.4 Configure Pooled Connection (Recommended)

For better performance with Rails, use connection pooling:

1. Go to **Connection Details**
2. Toggle **Pooled connection**
3. Copy the pooled connection string (uses port 5432 instead of direct)

```
# Direct (for migrations)
postgresql://user:pass@ep-xxx.neon.tech/myapp_production?sslmode=require

# Pooled (for app - better performance)
postgresql://user:pass@ep-xxx.neon.tech:5432/myapp_production?sslmode=require
```

### 3.5 Rails database.yml Configuration

```yaml
# config/database.yml
production:
  primary: &primary_production
    adapter: postgresql
    encoding: unicode
    pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
    url: <%= ENV["DATABASE_URL"] %>
```

---

## 4. Render Backend Setup

### 4.1 Create Web Service

1. Go to [render.com](https://render.com) and sign in
2. Click **New +** → **Web Service**
3. Connect your GitHub repository
4. Select the repository

### 4.2 Configure Build Settings

| Setting | Value | Notes |
|---------|-------|-------|
| **Name** | `myapp-api` | Will be part of URL |
| **Region** | Same as Neon | Reduces latency |
| **Branch** | `main` | Or your production branch |
| **Root Directory** | `backend` | If monorepo, otherwise leave blank |
| **Runtime** | Ruby | Auto-detected usually |
| **Build Command** | `bundle install && bundle exec rails db:migrate` | See below |
| **Start Command** | `bundle exec rails server -b 0.0.0.0 -p $PORT` | Required format |

### 4.3 Build Command Options

**Basic (recommended):**
```bash
bundle install && bundle exec rails db:migrate
```

**With asset precompilation (if needed):**
```bash
bundle install && bundle exec rails assets:precompile && bundle exec rails db:migrate
```

**With seed data (first deploy only):**
```bash
bundle install && bundle exec rails db:migrate db:seed
```

### 4.4 Environment Variables

Click **Advanced** → **Add Environment Variable**:

| Variable | Value | Notes |
|----------|-------|-------|
| `DATABASE_URL` | `postgresql://...@neon.tech/...` | From Neon |
| `RAILS_ENV` | `production` | Required |
| `RAILS_MASTER_KEY` | Your key from `config/master.key` | Required for credentials |
| `SECRET_KEY_BASE` | Generate with `rails secret` | Or use master.key |
| `FRONTEND_URL` | `https://yourapp.netlify.app` | For CORS |
| `CLERK_JWKS_URL` | `https://.../.well-known/jwks.json` | If using Clerk |
| `RESEND_API_KEY` | `re_...` | If using Resend |
| `MAILER_FROM_EMAIL` | `noreply@yourdomain.com` | If using Resend |
| `AWS_ACCESS_KEY_ID` | `AKIA...` | If using S3 |
| `AWS_SECRET_ACCESS_KEY` | `...` | If using S3 |
| `AWS_S3_BUCKET` | `myapp-documents` | If using S3 |
| `AWS_REGION` | `us-east-1` | If using S3 |

### 4.5 Instance Type

| Type | RAM | CPU | Cost | Notes |
|------|-----|-----|------|-------|
| **Free** | 512 MB | Shared | $0 | Sleeps after 15min inactivity |
| **Starter** | 512 MB | 0.5 | $7/mo | Always on, recommended |
| **Standard** | 2 GB | 1 | $25/mo | For higher traffic |

⚠️ **Free tier note**: Service "spins down" after 15 minutes of inactivity. First request after sleep takes 30-60 seconds.

### 4.6 Create Service

Click **Create Web Service** and wait for the first deploy.

### 4.7 Verify Deployment

Once deployed, test the health endpoint:
```bash
curl https://myapp-api.onrender.com/up
# Should return 200 OK
```

---

## 5. Netlify Frontend Setup

### 5.1 Prepare Frontend

Before deploying, ensure these files exist:

**`frontend/public/_redirects`** (critical for SPA routing):
```
# SEO files - serve directly
/robots.txt    /robots.txt    200
/sitemap.xml   /sitemap.xml   200

# SPA fallback - all other routes go to index.html
/*    /index.html   200
```

Without this file, direct navigation to routes like `/admin` will 404.

### 5.2 Create Site

1. Go to [netlify.com](https://netlify.com) and sign in
2. Click **Add new site** → **Import an existing project**
3. Connect GitHub and select your repository

### 5.3 Configure Build Settings

| Setting | Value | Notes |
|---------|-------|-------|
| **Branch to deploy** | `main` | Or your production branch |
| **Base directory** | `frontend` | If monorepo, otherwise leave blank |
| **Build command** | `npm run build` | Standard Vite build |
| **Publish directory** | `frontend/dist` | Vite output directory |

### 5.4 Environment Variables

Go to **Site settings** → **Environment variables**:

| Variable | Value | Notes |
|----------|-------|-------|
| `VITE_API_URL` | `https://myapp-api.onrender.com` | Your Render URL |
| `VITE_CLERK_PUBLISHABLE_KEY` | `pk_live_...` | If using Clerk |
| `VITE_PUBLIC_POSTHOG_KEY` | `phc_...` | If using PostHog |
| `VITE_PUBLIC_POSTHOG_HOST` | `https://us.i.posthog.com` | If using PostHog |

### 5.5 Deploy

Click **Deploy site**. Netlify will:
1. Clone your repo
2. Run `npm install`
3. Run `npm run build`
4. Deploy to CDN

### 5.6 Verify Deployment

1. Visit your Netlify URL (e.g., `myapp.netlify.app`)
2. Navigate to different routes (e.g., `/about`, `/admin`)
3. Refresh on those routes - should NOT 404
4. Check browser console for API errors

---

## 6. Custom Domain Configuration

### 6.1 Domain Options

| Setup | Domains | Notes |
|-------|---------|-------|
| **Simple** | `yourapp.com` (frontend), `api.yourapp.com` (backend) | Most common |
| **Single** | `yourapp.com`, API at `/api/*` | Requires proxy setup |
| **Subdomains** | `app.yourapp.com`, `api.yourapp.com` | Clear separation |

### 6.2 Netlify Custom Domain

1. Go to **Domain settings** → **Add custom domain**
2. Enter your domain (e.g., `yourapp.com`)
3. Add DNS records:

**Option A: Netlify DNS (recommended)**
- Point your domain's nameservers to Netlify
- Netlify manages all DNS

**Option B: External DNS**
Add these records to your DNS provider:

| Type | Name | Value |
|------|------|-------|
| A | `@` | `75.2.60.5` |
| CNAME | `www` | `yoursite.netlify.app` |

### 6.3 Render Custom Domain

1. Go to your web service → **Settings** → **Custom Domains**
2. Click **Add Custom Domain**
3. Enter subdomain (e.g., `api.yourapp.com`)
4. Add DNS record:

| Type | Name | Value |
|------|------|-------|
| CNAME | `api` | `yourapp-api.onrender.com` |

### 6.4 SSL Certificates

Both Netlify and Render automatically provision SSL certificates via Let's Encrypt. Just wait a few minutes after adding the domain.

### 6.5 Update Environment Variables

After setting up custom domains, update:

**Render:**
```
FRONTEND_URL=https://yourapp.com
```

**Netlify:**
```
VITE_API_URL=https://api.yourapp.com
```

---

## 7. Environment Variables Reference

### Backend (Render)

```bash
# Required
DATABASE_URL=postgresql://user:pass@ep-xxx.neon.tech/myapp_production?sslmode=require
RAILS_ENV=production
RAILS_MASTER_KEY=abc123...  # From config/master.key
SECRET_KEY_BASE=xyz789...   # Or use RAILS_MASTER_KEY

# CORS
FRONTEND_URL=https://yourapp.com

# Authentication (Clerk)
CLERK_JWKS_URL=https://clerk.yourapp.com/.well-known/jwks.json

# Email (Resend)
RESEND_API_KEY=re_...
MAILER_FROM_EMAIL=noreply@yourapp.com

# File Storage (S3)
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_S3_BUCKET=yourapp-documents
AWS_REGION=us-east-1

# Optional
RAILS_LOG_LEVEL=info
RAILS_MAX_THREADS=5
```

### Frontend (Netlify)

```bash
# Required
VITE_API_URL=https://api.yourapp.com

# Authentication (Clerk)
VITE_CLERK_PUBLISHABLE_KEY=pk_live_...

# Analytics (PostHog)
VITE_PUBLIC_POSTHOG_KEY=phc_...
VITE_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
```

### Getting RAILS_MASTER_KEY

```bash
# In your backend directory
cat config/master.key
# Copy this value to Render
```

If `master.key` doesn't exist:
```bash
rails credentials:edit
# This creates the file
```

### Generating SECRET_KEY_BASE

```bash
rails secret
# Copy the output
```

---

## 8. Post-Deployment Checklist

### Immediately After Deploy

```
□ Health check endpoint works (/up or /health)
□ Frontend loads without console errors
□ API requests work (check Network tab)
□ Authentication works (sign in/out)
□ Database connected (create a test record)
□ CORS working (no CORS errors in console)
```

### First User Setup

```
□ First user signs up and becomes admin
□ Admin can access protected routes
□ Invite system works (if applicable)
```

### Full Functionality Check

```
□ All CRUD operations work
□ File uploads work (if using S3)
□ Email sending works (if using Resend)
□ All pages render correctly
□ Mobile responsive
□ PWA installable (if applicable)
```

### Monitoring

```
□ Set up error tracking (Sentry, etc.)
□ Set up uptime monitoring (Better Uptime, etc.)
□ Check Render logs for errors
□ Check Neon metrics for performance
```

---

## 9. Common Issues & Solutions

### Frontend Issues

#### 404 on page refresh
**Cause**: SPA routing not configured  
**Fix**: Add `_redirects` file to `public/` folder:
```
/*    /index.html   200
```

#### API requests fail with CORS error
**Cause**: Backend CORS not configured for frontend URL  
**Fix**: Update `FRONTEND_URL` env var on Render, redeploy

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

#### Environment variables not working
**Cause**: Vite requires `VITE_` prefix  
**Fix**: Rename variables:
```bash
# Wrong
API_URL=https://...

# Correct
VITE_API_URL=https://...
```

### Backend Issues

#### "Relation does not exist" error
**Cause**: Migrations haven't run  
**Fix**: 
1. Check Render build logs
2. Verify build command includes `db:migrate`
3. Try manual deploy with: `bundle exec rails db:migrate`

#### App sleeps and first request times out
**Cause**: Free tier sleeps after 15min  
**Fix**: 
1. Upgrade to Starter ($7/mo)
2. Or set up a cron to ping your health endpoint every 10 minutes

#### "PG::ConnectionBad" or database errors
**Cause**: Wrong DATABASE_URL or Neon sleeping  
**Fix**:
1. Verify DATABASE_URL is correct
2. Check Neon dashboard - project might be paused
3. Enable "Always on" in Neon settings

#### Rails master key / credentials error
**Cause**: Missing RAILS_MASTER_KEY  
**Fix**: 
1. Get key: `cat config/master.key`
2. Add to Render env vars as `RAILS_MASTER_KEY`

### Database Issues

#### Neon connection limit exceeded
**Cause**: Too many connections from app  
**Fix**: 
1. Use pooled connection string
2. Reduce `RAILS_MAX_THREADS`
3. Enable connection pooling in database.yml

#### "SSL required" error
**Cause**: Neon requires SSL  
**Fix**: Ensure `?sslmode=require` is in DATABASE_URL

### Deployment Issues

#### Build fails with "out of memory"
**Cause**: Starter instance too small for build  
**Fix**: 
1. Temporarily upgrade during deploy
2. Optimize build (remove unused gems)

#### Deploy succeeds but app crashes
**Cause**: Missing env vars or config  
**Fix**: 
1. Check Render logs
2. Verify all required env vars are set
3. Test locally with production env

---

## 10. Cost Overview

### Free Tier Limitations

| Service | Free Limit | What Happens |
|---------|------------|--------------|
| **Netlify** | 100 GB bandwidth | Site goes offline |
| **Render** | 750 hours/month, sleeps | 30-60s cold start |
| **Neon** | 0.5 GB storage, 190 compute hours | DB pauses |

### Recommended Paid Setup

| Service | Plan | Monthly Cost | Notes |
|---------|------|-------------|-------|
| Netlify | Pro | $19 | 1 TB bandwidth, team features |
| Render | Starter | $7 | Always on, no sleep |
| Neon | Launch | $19 | 10 GB storage, always on |
| **Total** | | **$45/mo** | Production-ready |

### Budget Setup (Minimum Viable)

| Service | Plan | Monthly Cost | Notes |
|---------|------|-------------|-------|
| Netlify | Free | $0 | 100 GB bandwidth |
| Render | Starter | $7 | Worth it to avoid sleep |
| Neon | Free | $0 | Pauses when idle |
| **Total** | | **$7/mo** | Basic production |

### Scaling Costs

As traffic grows:

| Traffic Level | Netlify | Render | Neon | Total |
|---------------|---------|--------|------|-------|
| 1K users/mo | Free | $7 | Free | $7 |
| 10K users/mo | Free | $7 | $19 | $26 |
| 50K users/mo | $19 | $25 | $19 | $63 |
| 100K+ users/mo | $19 | $85+ | $69+ | $173+ |

---

## Quick Start Checklist

### 1. Database (Neon) - 5 minutes
```
□ Create Neon account
□ Create project
□ Copy DATABASE_URL
□ Note: Use pooled connection for production
```

### 2. Backend (Render) - 10 minutes
```
□ Create Render account
□ Connect GitHub
□ Create Web Service
□ Set root directory (if monorepo)
□ Set build command: bundle install && bundle exec rails db:migrate
□ Set start command: bundle exec rails server -b 0.0.0.0 -p $PORT
□ Add environment variables:
  - DATABASE_URL
  - RAILS_ENV=production
  - RAILS_MASTER_KEY
  - FRONTEND_URL
  - (other service keys)
□ Deploy and test /up endpoint
```

### 3. Frontend (Netlify) - 5 minutes
```
□ Create _redirects file in public/
□ Create Netlify account
□ Connect GitHub
□ Set base directory (if monorepo)
□ Set build command: npm run build
□ Set publish directory: dist
□ Add environment variables:
  - VITE_API_URL (Render URL)
  - (other VITE_ vars)
□ Deploy and test
```

### 4. Custom Domain (Optional) - 15 minutes
```
□ Add domain to Netlify
□ Add subdomain to Render (api.yourapp.com)
□ Configure DNS records
□ Wait for SSL provisioning
□ Update FRONTEND_URL on Render
□ Update VITE_API_URL on Netlify
□ Redeploy both
```

---

## Useful Commands

### Check Render Logs
```bash
# In Render dashboard: Logs tab
# Or use Render CLI:
render logs --service myapp-api
```

### Run Rails Console on Render
```bash
# Go to Render dashboard → Shell tab
bundle exec rails console
```

### Run Migrations Manually
```bash
# In Render Shell
bundle exec rails db:migrate
```

### Check Database Connection
```bash
# In Render Shell
bundle exec rails runner "puts ActiveRecord::Base.connection.execute('SELECT 1')"
```

---

*Last updated: January 2026*
