# Portal PR 7 QA: message attachments and file requests (Nov 13, 2026)

Affected-flow QA, run by the agent with synthetic data on an isolated local database. No real client data or email.

## Environment

- Commit `fc7b3727`. Rails API in test mode with E2E headers, Vite dev server, and a local cookie proxy for the role.
- Headless Chromium through Playwright at 1280×900 and 390×844, with reduced motion turned on.
- Each width started from a reset fixture: one client company with a manual biweekly schedule, two pay periods, three employees and two library files (one with a very long name).

## Cases (each passed at both widths)

| Case | What was checked |
| --- | --- |
| M1 Staff request a missing timesheet | Request a file dialog: employee search, pay period, due date and message. The request lands in the period's conversation as "Waiting for the file". The period page says one requested file is outstanding and offers no Mark paid. A `file_requested` event is recorded. |
| M2 Client uploads the response | "Upload requested file" picks a file from the device and sends it in the request. The status becomes "File sent, waiting for Cornerstone". The file is saved as `payroll_source` for the requested employee. No separate `client_upload` alert is recorded. |
| M3 Staff accept from the Client Inbox | The inbox shows a File request row with that status. Opening it goes to Client Messages; Accept file moves the request to Accepted. Back to Client Inbox returns to the inbox, and the row has left Waiting on staff. |
| M4 Preview and download from a bubble | Preview opens, Escape closes it and focus returns to the Preview button. Download saves the original name. One preview and one download audit entry are added. |
| M5 Several files, server picker, failed network | Choose existing file finds the long-named file by server search, and keyboard Space selects it. A device upload is added. The first send is aborted at the network: the text and files are kept. The retry creates one conversation with two attachments and no second copy of the upload. |
| M6 Back, filter and draft | The filter is kept in the URL (`conversations=open`). The reply draft survives switching conversations and a reload. On the phone, in-page Back returns focus to the row, and browser Back and Forward work. |

No horizontal overflow at 390. There were no page errors.

## Not covered

Real Clerk sign-in and Cable revocation, native phone keyboards, Safari, and real email delivery (email stays off).
