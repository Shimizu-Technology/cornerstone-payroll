# Cornerstone Payroll API

Rails 8 API-only backend for Cornerstone Payroll, a Guam payroll system.

## Requirements
- Ruby 3.3.14+
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

## Authentication (Clerk)

Set `AUTH_ENABLED=false` to bypass authentication locally. `USER_ID` and `COMPANY_ID` scope requests in this mode.

To test real sign-in locally, configure the API and web app with keys from the same Clerk development instance. Set `AUTH_ENABLED=true` in the API and `VITE_AUTH_ENABLED=true` in the web app. Create your test account in Clerk, then copy its exact `user_…` ID from the Clerk Dashboard. Bind that ID to your intended existing local admin before signing in. In the local development console (`RAILS_ENV=development bin/rails console`), use the local Payroll user ID:

```ruby
admin = User.find(123) # Replace with the ID of your local admin row.
raise "Expected a local admin" unless admin.organization_admin?
admin.update!(clerk_id: "user_REPLACE_WITH_CLERK_DEV_ID", invitation_status: "accepted",
  clerk_invitation_id: nil, invite_nonce_digest: nil, invite_nonce_expires_at: nil)
```

This console bootstrap is for a local development database. Once signed in, use Settings → Users for invitations and recovery. `FRONTEND_URL` sets the invitation redirect base. Email delivery uses `RESEND_API_KEY` and `MAILER_FROM_EMAIL`.

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
