# AIRE + Cornerstone staging v2

This stack runs successful `staging-v2` commits from both repositories on the MacBook Pro. It is independent from the existing staging environment:

- Colima profile: `aire-payroll-staging-v2`
- Compose project: `aire-payroll-staging-v2`
- local ports: AIRE `8889`, payroll `8890`
- separate PostgreSQL and upload volumes
- separate service checkout, deployment state, backups, logs, and LaunchAgent

The applications communicate only over the private Compose integration network. Browser traffic reaches the Caddy frontends, which proxy same-origin API, Action Cable, and Active Storage requests. The databases and Rails containers publish no host ports.

Cornerstone stores staging-only generated artifacts in its persistent `payroll_storage` volume. Local storage is accepted only when all explicit staging guards are present; production still requires R2.

The seed fixture follows the current target-run cutoff contract: the upcoming run locks seven calendar days after the previous adjacent regular payday. It creates a finalized period for reconciliation and an upcoming period for the connected payroll workflow. All fixture people and identifiers are synthetic.

The LaunchAgent checks every three minutes for successful `staging-v2` workflow runs. A temporary GitHub lookup failure leaves the current containers running. A commit pair that fails its deployment health check is held until either commit changes, preventing repeated backups and failed deploy loops; an operator can rerun `deploy.sh` directly after correcting an external problem. Backups run before deployment and at least daily, retain 14 days, and include both PostgreSQL databases and both upload volumes.

Never point this stack at production data, production Clerk instances, or the existing staging databases and volumes.
