# AIRE + Cornerstone staging

This stack runs the successful `staging` commits from both repositories on the MacBook Pro. It uses two isolated PostgreSQL databases, persistent local upload volumes, staging-only Clerk instances, and a private Docker integration network.

The fixture creates two semimonthly payrolls:

- a finalized AIRE period for testing Cornerstone's manual entry and exact-entry reconciliation flow;
- the next live AIRE period for testing direct import, calculation, commitment, check delivery, and automatic AIRE status synchronization.

No production database, employee, key, or hostname is used. The seed scripts refuse to run unless the database name and explicit staging flags match.

The MacBook binds AIRE to `127.0.0.1:8789` and payroll to `127.0.0.1:8790`. Tailscale Serve and the existing Mac mini Cloudflare tunnel provide HTTPS without exposing database or API container ports.
