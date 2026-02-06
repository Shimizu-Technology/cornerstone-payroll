# Cornerstone Payroll API

Rails 8 API-only backend for Cornerstone Payroll, a Guam payroll system.

## Requirements
- Ruby 3.3+
- PostgreSQL 14+
- Bundler

## Setup
```bash
cp .env.example .env
bundle install
bin/rails db:create db:migrate
bin/rails db:encryption:init
# Paste the generated keys into .env
```

## Run
```bash
bin/rails s -p 3000
```

## Authentication (WorkOS)
- OAuth endpoints live under `/api/v1/auth/*`
- Set `AUTH_ENABLED=false` to bypass auth locally
- When auth is disabled, `USER_ID` and `COMPANY_ID` are used for scoping
- Configure `JWT_SECRET` (or rely on `SECRET_KEY_BASE`) and `JWT_ISSUER` for JWT verification
- Users are persisted in the database and assigned roles (`admin`, `manager`, `employee`)
- `DEFAULT_USER_ROLE` is used for new users (first user per company becomes `admin`)
- User invitations are sent via email from `/api/v1/admin/user_invitations`
- Set `FRONTEND_URL` for the invite link base
- Resend email delivery uses `RESEND_API_KEY` and `MAILER_FROM_EMAIL`
- Set `WORKOS_CONNECTION_ID` or `WORKOS_ORGANIZATION_ID` to direct SSO login

## CORS
- Set `CORS_ORIGINS` to a comma-separated list of allowed frontend origins

## Tests & Quality
```bash
bundle exec rspec
bundle exec rubocop
bin/brakeman
```

## Deployment
- Uses Kamal. Configure `config/deploy.yml` with your server and registry.
- Set `FORCE_SSL=true` in production when behind an SSL proxy.
