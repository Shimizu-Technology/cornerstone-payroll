# Production encryption incident: August 24, 2026

## Summary

The Cornerstone Payroll employee list returned HTTP 500 for clients with encrypted employee data. Both `payroll.shimizu-technology.com` and the legacy Netlify URL were affected because they use the same Render API.

The API was healthy for authentication, companies, dashboard data, and departments. The failing employee request raised `ActiveRecord::Encryption::Errors::Decryption` while reading the last four digits of an employee SSN.

## Cause

Production already had a complete Active Record Encryption key set in encrypted Rails credentials. PR #125 added explicit production environment-key support and resolved each key from the Render environment before Rails credentials. Render also had a complete but different key set. The deploy therefore selected keys that could not decrypt existing ciphertext.

The readiness gate checked that effective keys were present. It did not check that duplicate sources agreed or that the effective keys could decrypt persisted records.

## Evidence

Read-only production probes on August 24 established that:

- the Rails credential and Render environment key sets were both complete;
- the two key sets did not match;
- the environment-selected keys failed to decrypt an employee SSN and a time-tracking shared secret; and
- the credential-backed keys completed all 341 encrypted-field reads attempted across employees, time-tracking sources, change requests, and active sessions without a decryption failure.

The probes printed no key material or decrypted values and made no customer-data changes.

## Recovery and prevention

The recovery keeps the Rails credential set authoritative for this existing deployment. It does not rotate keys or rewrite ciphertext.

The application now:

- selects one complete key set atomically instead of mixing individual values from two sources;
- preserves the credential-backed production key set when it exists;
- logs a safe error and fails the readiness gate when duplicate production sources are incomplete or disagree;
- keeps production credentials out of development and test encryption; and
- makes the live readiness gate decrypt every supported persisted encrypted value without printing plaintext.

After deployment, remove the obsolete Render encryption variables from both the web and worker services. Rerun the readiness gate and retain its evidence after the duplicate source is removed.
