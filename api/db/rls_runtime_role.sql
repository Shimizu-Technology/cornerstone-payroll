-- Lead only. Run with psql as the direct migration owner. Repeat the grants
-- below if existing tables are added by a different owner.
CREATE ROLE payroll_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
\password payroll_app
GRANT USAGE ON SCHEMA public TO payroll_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payroll_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payroll_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO payroll_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO payroll_app;
