# Credentials Setup Guide

Everything is built and ready — just need these credentials plugged in.

## 1. WorkOS Authentication

**Status:** Code written, needs redirect URI configured

### What you need to do:
1. Go to WorkOS Dashboard → Redirects
2. Add: `http://localhost:5173/callback`
3. (For production later: add your Netlify URL)

### Already configured:
- ✅ Client ID: `client_01KGPPS3Z8M8K1KNEXP0H2102H`
- ✅ API Key: in `.env` files
- ✅ Frontend auth flow: written
- ✅ Backend token validation: written

---

## 2. Cloudflare R2 (Pay Stub Storage)

**Status:** Code written, needs bucket + credentials

### What you need to do:

#### A. Create R2 Bucket
1. Cloudflare Dashboard → R2 → Create bucket
2. Name: `cornerstone-payroll-paystubs`
3. Location: Auto (or choose US)

#### B. Create API Token
1. R2 → Manage R2 API Tokens → Create API token
2. Permissions: **Object Read & Write**
3. Specify bucket: `cornerstone-payroll-paystubs`
4. Copy the credentials

#### C. Give me these values:
```
R2_ACCOUNT_ID=<your-cloudflare-account-id>
R2_ACCESS_KEY_ID=<from-token-creation>
R2_SECRET_ACCESS_KEY=<from-token-creation>
R2_BUCKET=cornerstone-payroll-paystubs
R2_PUBLIC_URL=<optional-if-you-enable-public-access>
```

### Where they go:
- `api/.env` — I'll add them
- `api/.env.example` — already has placeholders

---

## 3. Database (Already Done)

Local PostgreSQL is set up and working:
- Database: `cornerstone_payroll_development`
- User: `jerry`
- All migrations run, schema ready

---

## Quick Reference

| Service | Status | Blocking |
|---------|--------|----------|
| WorkOS Auth | Need redirect URI | Phase 6 |
| Cloudflare R2 | Need bucket + creds | Phase 4 |
| PostgreSQL | ✅ Done | — |
| Tax Calculator | ✅ Done | — |
| Pay Periods API | ✅ Done | — |
| Employee CRUD | ✅ Done | — |

---

## What's Ready to Test NOW

Even without the credentials above, you can:

1. **Start the API:**
   ```bash
   cd api && ~/.rbenv/shims/rails server
   ```

2. **Start the frontend:**
   ```bash
   cd web && npm run dev
   ```

3. **Test the full payroll flow:**
   - Create employees
   - Create pay periods
   - Run payroll calculations
   - See tax breakdowns

Auth is bypassed locally (uses `COMPANY_ID=1` env var).

---

## When You're Ready

Just paste the R2 credentials in Telegram and I'll:
1. Add them to the `.env` files
2. Test the PDF generation
3. Verify uploads work

For WorkOS, just add the redirect URI and let me know — I'll test the login flow.
