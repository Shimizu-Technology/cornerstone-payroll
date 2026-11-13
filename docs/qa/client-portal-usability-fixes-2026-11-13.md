# Client portal usability fixes QA (Nov 13, 2026)

Affected-flow QA, run by the agent with synthetic data on an isolated local database. No real client data, no real email, no Clerk.
These fixes answer the defects in the MoSa weekend rehearsal (D03, D05, D06, D07, D08, D09, D10).

## Environment

- Rails API in test mode with E2E identity headers, Vite dev server, and a local cookie proxy that picks the role (client, staff, an inactive client, an unknown login).
- Headless Chromium through Playwright at 1440×900 and 390×844, reduced motion on. The database was rebuilt from the seed between widths.
- Fixture: one MoSa-style client with a manual biweekly schedule, a regular pay run Oct 19 – Nov 1, 2026, 16 hourly employees and two variable-pay owners, and a synthetic Revel PDF with an unmatched "Ghost, Gary" row.

## Cases (each passed at both widths)

| Case | What was checked |
| --- | --- |
| D05 Client Home to Payroll Files | The Home card names the period, shows its status ("Waiting for files"), explains Payroll Files versus Pay Periods, and "Send payroll files" opens that period. At 390 it sits above the first stat tile. The client then sends the PDF with no changes; Home shows "Sent to Cornerstone". |
| D03 Owner pay, apply and calculate | Staff confirm receipt and open the files in import review. Apply is off with the reason pinned in view. Each owner's pay is entered and saved on their own row without leaving the review; Apply stays off until the replace-existing confirmation is checked. Apply imports 18 employees and clears the pending portal revision. The worksheet then shows both owner amounts and Recalculate works: Monique gross 4,500.00, Sara 3,500.00. A combined owner amount is still refused (no combined field exists; backend spec). |
| D06 Wording | Staff page and review say "Review these submitted files", "Don’t use this submission — record why", "Client revision N" and "Import version N · reference …". Identifiers stay as secondary detail. |
| D10 Long phone review | "Needs attention" lists each blocker with a jump button; "Next row needing attention" focuses the first row that needs an outcome; the Apply reason stays inside the viewport at the top and mid-scroll. |
| D07 Archived period file | A client sees "Kept with this period as a record. Ask Cornerstone if you need it." and no Preview or Download. Staff can still download the retained file. |
| D09 Invite failure | Creating a user with Clerk absent shows an amber "Review this action" notice: the account exists, no invitation was sent, with "Retry invitation". No green "Completed". Retry fails the same way and stays a warning. The user row exists, active, with a pending invite. |
| D08 Inactive login | A refused login gets "This sign-in cannot open an account … turned off … Contact Cornerstone" with Try again, not an empty staff Home. An unknown login gets the same screen. |

No horizontal overflow at 390 on the pages checked. No page errors.

## Not covered

- Real Clerk sign-in. The local test sign-in answers a plain 401 for an inactive login; the Clerk "Account inactive" wording and the Login-page notice are covered by unit tests only.
- Native phone keyboards, Safari, and real email delivery.
- The archived file was set with SQL on the local database, not through the Client Documents archive button.
- Organization creation still shows its own invitation outcome as before (not changed here).
