# AIRE + Cornerstone staging

This stack runs the successful `staging` commits from both repositories on the MacBook Pro. It uses two isolated PostgreSQL databases, persistent local upload volumes, staging-only Clerk instances, and a private Docker integration network.

Cornerstone's staging API and worker store generated check packages and other private artifacts in their shared `payroll_storage` volume. The `R2_STORAGE_BACKEND=local` setting is accepted only for the explicit staging deployment; production still requires R2 credentials. The staging backup includes this volume so saved packages survive redeploys and are recoverable.

The fixture creates two semimonthly payrolls:

- a finalized AIRE period for testing Cornerstone's manual entry and exact-entry reconciliation flow;
- the next live AIRE period for testing direct import, calculation, commitment, check delivery, and automatic AIRE status synchronization.

No production database, employee, key, or hostname is used. The seed scripts refuse to run unless the database name and explicit staging flags match.

The MacBook binds AIRE to `127.0.0.1:8789` and payroll to `127.0.0.1:8790`. Tailscale Serve and the existing Mac mini Cloudflare tunnel provide HTTPS without exposing database or API container ports.

The LaunchAgent checks successful staging workflow runs with the authenticated GitHub CLI. The service account must remain signed in to GitHub; a temporary lookup failure leaves the deployed containers running and does not prevent the scheduled backup.

## Backups and recovery

The LaunchAgent checks every three minutes for a successful `staging` build and runs a backup at least once every 24 hours, even when no deployment occurs. Deployments also back up the current state before migrations. Backups are retained for 14 days and include:

- compressed PostgreSQL dumps for AIRE and Cornerstone;
- compressed archives of the AIRE and Cornerstone upload volumes.

The default backup directory is `backups/` in the persistent service checkout. Override it with `AIRE_PAYROLL_STAGING_BACKUP_DIR` when a separate disk or synchronized folder is preferred.

To restore, stop the application services while leaving both databases running. Decompress each SQL dump into the matching database with `psql`. Restore each storage archive into its matching Compose volume through a temporary, network-disabled container. Run `deploy.sh` with the last known-good payroll and AIRE commit SHAs, then require `healthcheck.sh` to pass before reopening the public routes. Never restore a staging backup into production.
