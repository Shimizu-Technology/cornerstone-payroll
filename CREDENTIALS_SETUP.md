# Credentials Setup Guide

Everything is built and ready — just need these credentials plugged in.

---

## 1. WorkOS Authentication

**Status:** ✅ Code complete, needs redirect URI

### What you need to do:
1. Go to [WorkOS Dashboard](https://dashboard.workos.com) → Redirects
2. Add: `http://localhost:5173/callback`
3. (For production: add your Netlify URL later)

### Already configured:
- ✅ Client ID: `client_01KGPPS3Z8M8K1KNEXP0H2102H`
- ✅ API Key: in `api/.env`
- ✅ Frontend auth flow: Login page, callback handler, protected routes
- ✅ Backend auth: Token exchange, session management

### To enable auth:
```bash
# In web/.env
VITE_AUTH_ENABLED=true
```

---

## 2. Cloudflare R2 (Pay Stub Storage)

**Status:** ✅ Code complete, needs bucket + credentials

### What you need to do:

#### A. Create R2 Bucket
1. [Cloudflare Dashboard](https://dash.cloudflare.com) → R2 → Create bucket
2. Name: `cornerstone-payroll-paystubs`
3. Location: Auto (or US West)

#### B. Create API Token
1. R2 → Manage R2 API Tokens → Create API token
2. Permissions: **Object Read & Write**
3. Specify bucket: `cornerstone-payroll-paystubs`
4. Copy the credentials

#### C. Give me these values (paste in Telegram):
```
R2_ACCOUNT_ID=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
```

I'll add them to `api/.env` — that's it!

---

## 3. What's Already Working (No Creds Needed)

You can test everything right now:

```bash
# Terminal 1 - Start API
cd api && ~/.rbenv/shims/rails server

# Terminal 2 - Start Frontend
cd web && npm run dev
```

Go to http://localhost:5173 and:
- ✅ Create/manage employees
- ✅ Create pay periods
- ✅ Run payroll calculations
- ✅ See tax breakdowns (federal, SS, Medicare)
- ✅ View dashboard with YTD stats
- ✅ Generate reports

Auth is bypassed locally (uses `COMPANY_ID=1`).
PDF generation works, just stored in memory (not R2).

---

## 4. Quick Reference

| Feature | Status | Needs |
|---------|--------|-------|
| Employee CRUD | ✅ Working | — |
| Pay Periods | ✅ Working | — |
| Payroll Calc | ✅ Working | — |
| Tax Calculator | ✅ Working | — |
| Dashboard | ✅ Working | — |
| Reports | ✅ Working | — |
| PDF Pay Stubs | ✅ Code done | R2 creds |
| Authentication | ✅ Code done | WorkOS redirect |

---

## 5. Files That Need Credentials

When you give me the creds, I'll update:

**API (`api/.env`):**
```env
# R2 Storage
R2_ACCOUNT_ID=xxx
R2_ACCESS_KEY_ID=xxx
R2_SECRET_ACCESS_KEY=xxx
R2_BUCKET=cornerstone-payroll-paystubs
```

**Frontend (`web/.env`):**
```env
# Enable auth when ready
VITE_AUTH_ENABLED=true
```

---

## 6. Test Checklist (For You)

After credentials are in:

- [ ] Login with WorkOS → redirects to dashboard
- [ ] Create a pay period
- [ ] Add employees (or use existing)
- [ ] Run payroll calculation
- [ ] Verify tax amounts look correct
- [ ] Generate PDF pay stub
- [ ] Download PDF pay stub
- [ ] Batch generate all pay stubs for a period
- [ ] Approve → Commit pay period (locks YTD)

---

That's it! Just paste the R2 credentials when ready and we're live. 🚀
