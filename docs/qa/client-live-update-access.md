# Client live-update access

During native I07 testing, removing the selected client's assignment correctly denied that client's employee and payroll records. Its portal connection then retried into the operator's home client while the original tab still displayed the removed client's name and “Live updates on.” The native server log confirmed that transition. Saved payroll and source history were unchanged.

Tickets and portal messaging now reject an explicitly requested inaccessible client instead of falling back to the home client. The subscription captures its selected company, honors terminal server closure and authentication/access denial, and ignores old callbacks or another company's payload. Transient failures retain fresh-ticket recovery for the same company.

The message panel clears inaccessible conversations and blocks sending until a new authorized connection succeeds. Refresh access reloads available clients. Company changes remount the panel; subscription setup that finishes after unmount is immediately cleaned up. Late list, conversation and mutation responses cannot restore cleared data after revocation.

Acceptance:

- Inaccessible or malformed explicit client headers return 403 without a fallback ticket or conversation write; valid assigned-client and no-header home access remain supported.
- Terminal closure/rejection/401/403 stop retries. A transient outage recovers using the original client, and stale or mismatched messages are ignored.
- Revocation clears conversation data and disables sending. Failed recovery stays blocked; successful scoped reconnection restores the panel.
- Late setup and responses are harmless after unmount, revocation or client changes.
- Retest the original native I07 flow on desktop and mobile with saved payroll/source-history preservation and exact resource cleanup. The failed original evidence remains retained; automated tests do not replace that retake.
