# Employee app acceptance script (M4-12)

**What this is:** a step-by-step test of the employee app and the staff and client tools around it, run on the demo company. The owner, each Cornerstone reviewer and AI agents each follow it **separately** and fill in their own copy.
**Where it fits:** [go-live runbook](M4_GO_LIVE_RUNBOOK.md) step 1 (whole script, G8a pass 1) and step 2 (the **[critical]** rows again under enforced row-level security). The first pilot user runs sections B and C on their own records in step 4.
**Plan:** [Milestone 4 build plan](../MILESTONE_4_EMPLOYEE_APP_BUILD_PLAN_2026-11-24.md) §4 "M4-12"; [demo company plan](../DEMO_COMPANY_PLAN_2026-11-25.md) §§2–3.

This repo is public. Fill in your copy in the private evidence location, not here. Don't paste emails, codes, tokens or screenshots of persona inboxes into a PR or ticket. Demo data is fictional, but persona logins are real accounts.

---

## How to use this script

- Make a copy in the private evidence location for each run. Fill in the run details below.
- Work section by section. In each row do the **Step**, compare with **Expected**, tick **Pass** or **Fail**, and write anything odd in **Notes**, even on a pass.
- A row you can't run (for example a slice that isn't deployed) is **Pending**: write "Pending" and the reason in Notes. Pending isn't a pass.
- On a Fail, write what you saw and the time (Guam time), then carry on with the next row unless the row says **Stop on fail**. Raise an issue for each Fail.
- **Device** says where to run it. **Phone** means a real phone in its normal browser (one iPhone and one Android across the reviewers). **Desktop** means a laptop or desktop browser at full width. **Both** means run it on each.
- **[critical]** rows are rerun in go-live step 2.
- **Agent OK** rows can be run by an AI agent driving a browser with a persona login it was given for this run. Rows that need a persona's inbox, a real phone or a printed sheet are for people.
- Only one reviewer uses a persona at a time (demo plan §3). Sign out at the end of each section.

### Run details

| Field | Value |
|---|---|
| Tester (role) | |
| Date and start time (Guam) | |
| Payroll web commit / employee API commit / employee site deploy | |
| Phone model and browser | |
| Desktop browser | |
| Pass (1 = demo rehearsal, 2 = enforced RLS re-check) | |
| RLS mode at the time (readiness output reference) | |

### Addresses

| Site | Address |
|---|---|
| Staff and client site (Payroll) | the existing Payroll address |
| Demo employee site, main employer | `https://harborfinch.shimizu-technology.com` |
| Demo employee site, second employer | `https://harborfinch-catering.shimizu-technology.com` |

### Demo people (all fictional)

The seed (`rake demo:seed`) creates two employers. Harbor Finch Kitchen is the main one. Harbor Finch Catering gives one person a second employer. Persona logins are in the vault.

| Person | Employer | What they cover in this script |
|---|---|---|
| Maren Fable | Kitchen | **Client manager** login (invited by `rake demo:invite_clients`). Salaried. Claims employee access on the same login. Their own address request must be approved by someone else. |
| Tessa Vale | Kitchen | **Client user** login. No employee record. |
| Robin Lantern | Kitchen | Hourly, direct deposit, overtime weeks, QuickBooks history. First new sign-up by **email invite**. |
| Sky Lark | Kitchen | Hourly, paper check. **Printed code**, lockout and unlock, then revoke. |
| Kit Wren | Kitchen and Catering | One login, **two employers**, the employer picker. |
| Rowan Drift | Kitchen | Hourly with tips, paper check, uniform deduction, a **QuickBooks original stub**. |
| Ellis Quill | Kitchen | Salaried. Holds an unused invite for the **expired invite** test. |
| Avery Sprig | Kitchen | Part-time, paper check, one short period. **Former employee**, then **rehire**. |
| Drew Flint | Kitchen | Direct deposit, mid-year raise. **Corrected** stub and withdrawn W-2. |
| Quinn Sable | Kitchen | Already rehired in the seed. Pay from both spells shows in one list. |
| Jules Reed | Kitchen | Terminated in the seed before the app, with no termination-era link. Shows in staff lists only; can't be invited. |
| Morgan Tide | Catering | Catering-only employee, used for the wrong-company tests. |

Jules Reed was terminated before any app access existed, so they can't test former access: only an active employee can be invited (`api/app/services/employee_links/invite.rb:34`). Avery Sprig covers former access instead.

### Before you start

- [ ] Go-live runbook step 0 is done: slices deployed (including demo D6 and D7), demo seeded, client personas invited.
- [ ] Two-step sign-in is on (G3). The client personas have enrolled an authenticator app.
- [ ] The demo's employee app switches are on (runbook step 1). If D6 isn't deployed yet, run sections A and B now and mark section C Pending.
- [ ] You have the QuickBooks sample files from `rake demo:quickbooks_sample`, from the private evidence location.
- [ ] Note the demo's **Employee app rollout** counts before you start, so you can tell what this run changed.

---

## A. Cornerstone admin and accountant (staff site)

Sign in with your own Cornerstone staff login, with your second step. Choose **Harbor Finch Kitchen** in the client switcher.

### A1. Payroll run, stubs and checks

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A1.1 | Desktop · Agent OK | Open **Pay Periods**. Open the open (draft) period. | The period lists the Kitchen's active employees. Nothing says "demo", "practice" or "draft" anywhere a client could see. | ☐ Pass ☐ Fail | |
| A1.2 | Desktop · Agent OK | Enter hours for the hourly people (include Rowan Drift's tips), then **Calculate**. | Gross, FICA, Guam withholding and net show for each person. Rowan's tips are on their own line. | ☐ Pass ☐ Fail | |
| A1.3 | Desktop · Agent OK | **Approve**, then **Commit**. | The period shows **Committed**. Check numbers are assigned for paper-check employees. | ☐ Pass ☐ Fail | |
| A1.4 | Desktop · Agent OK | Open one employee's pay stub from the committed period. | The stub shows the SSN as the last 4 only, hours × rate on each earning line, taxes, deductions, take-home pay and YTD. | ☐ Pass ☐ Fail | |
| A1.5 | Desktop | **Print checks** for the period's paper checks, on **plain paper**. | A PDF of the checks generates. Line it up against a photocopy of check stock: names, amounts and the check number are in their boxes. Preprinted bank stock is refused for this company. | ☐ Pass ☐ Fail | |
| A1.6 | Desktop | Mark the printed checks printed and delivered. | Their payment status changes. Nothing is sent to a bank. | ☐ Pass ☐ Fail | |
| A1.7 | Desktop | Issue a corrective paycheck for Drew Flint on a committed period (any small fix). | The correction commits. Drew's original stub is kept as replaced, and a new stub marked **Corrected** exists. | ☐ Pass ☐ Fail | |

### A2. Year-end previews and W-2 copies

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A2.1 | Desktop · Agent OK | Open **Year-End Filing** for the Kitchen. Review the W-2GU checklist. | The checklist and previews look like a live client's. Review downloads work. | ☐ Pass ☐ Fail | |
| A2.2 | Desktop · Agent OK | Download the W-2GU review copy and the W-3SS PDF. | Both open. SSNs are truncated on employee copies. | ☐ Pass ☐ Fail | |
| A2.3 | Desktop | Try any electronic filing (EFW2 or SWICA file). | It's refused with the neutral "not available" wording a live client sees. Nothing is transmitted. | ☐ Pass ☐ Fail | |
| A2.4 | Desktop | Mark the W-2GU ready for 2026. | The readiness mark is current. | ☐ Pass ☐ Fail | |
| A2.5 | Lead · Render shell or API | Set the W-2 delivery to `mailed` (`PATCH /api/v1/admin/employee_app_settings/w2_delivery`), then post the 2026 copies (`POST /api/v1/admin/employee_tax_forms/post_copies { year: 2026 }`). There's no staff screen for these on main; use one if it has shipped since. | The job posts one copy per paid employee. `GET /api/v1/admin/employee_tax_forms?year=2026` lists them with notice status. Notices go only to allow-listed persona addresses. | ☐ Pass ☐ Fail | |
| A2.6 | Lead | Withdraw Drew Flint's posted copy with a reason (`POST /api/v1/admin/employee_tax_forms/:id/withdraw`). | Drew's copy is withdrawn. Checked on the phone in C9.3. | ☐ Pass ☐ Fail | |

### A3. QuickBooks original stubs

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A3.1 | Desktop | Open **Data Migration**, then **Original QuickBooks stubs**. Upload the sample stub PDF. | Each page is matched by name, pay date and net pay, shown in **Review each page**. | ☐ Pass ☐ Fail | |
| A3.2 | Desktop | Look at the sample's wrong-match page and its duplicate page. | The wrong page says "No check with this name, pay date and net pay…". The duplicate says "Another page matches this check…". Neither can be posted. | ☐ Pass ☐ Fail | |
| A3.3 | Desktop | Post Rowan Drift's matched page only. | It posts. Uploading the same page again says "Already posted. Skip this page." | ☐ Pass ☐ Fail | |

### A4. Changes to confirm

Run these after section C has made some changes.

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A4.1 | Desktop · Agent OK | Open **Pay Periods**. | A banner counts unconfirmed contact changes, with a **Changes to confirm** link. Creating a run still works ("You can still create this run"). | ☐ Pass ☐ Fail | |
| A4.2 | Desktop · Agent OK | Open **Changes to confirm**. Filter **To confirm**. | Every change from section C is listed with before and after, who made it, and its type (**Contact details**, **Address**, **Delivery consent**). | ☐ Pass ☐ Fail | |
| A4.3 | Desktop | Confirm one change, then use **Confirm all**. | "1 change confirmed on payroll.", then the rest. The Pay Periods banner count drops to 0. | ☐ Pass ☐ Fail | |

### A5. Employee app rollout and invites

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A5.1 | Both · Agent OK [critical] | Open **Employee app** (the **Employee app rollout** page). | Counts for **Ready to invite by email**, **Invited**, **Active**, **Need contact details**, **Locked** and **Former**. A **To do** card with **Locked sign-ups**, **Missing contact details**, **Expiring or expired invites** and **Sign-up resets to finish**. A **Cleanup report** lists Jules Reed under **Missing termination date** only if their record has none. The phone layout has no sideways scroll. | ☐ Pass ☐ Fail | |
| A5.2 | Desktop · Agent OK | Open **Branding and Help settings** from the rollout page. | **Employee app settings** opens with **Name, logo and colors** and **Help contacts**, and a **Preview** (Sign-in and Desktop) using sample data. | ☐ Pass ☐ Fail | |
| A5.3 | Desktop | Open Robin Lantern's record → **Employee app** panel. Choose **Invite** → **Email**. | The panel says **Invited**. The persona inbox gets an invite that "works once and expires in 14 days". | ☐ Pass ☐ Fail | |
| A5.4 | Desktop | On the rollout page, **Invite a group** → **Printed code**, select Sky Lark and Avery Sprig, **Create printed codes**. | A print dialog shows one sheet per person with the site address and a 10-letter code. "You can only see these codes now." Closing without printing asks for confirmation. | ☐ Pass ☐ Fail | |
| A5.5 | Desktop | Invite Ellis Quill by email and **don't** use it. Note the date. | Ellis shows **Invited**. Used in D4.2. | ☐ Pass ☐ Fail | |
| A5.6 | Desktop | Invite Kit Wren by email at **both** employers (switch the client to Harbor Finch Catering for the second). | Two invites. Kit uses both in C4. | ☐ Pass ☐ Fail | |
| A5.7 | Desktop | Invite Quinn Sable and Drew Flint by email. | Both **Invited**. | ☐ Pass ☐ Fail | |
| A5.8 | Desktop | Try to invite Jules Reed. | Refused: only active employees can be invited. | ☐ Pass ☐ Fail | |
| A5.9 | Desktop [critical] | After Sky Lark's lockout (C2.2), open Sky's record. | Status **Locked**, "Sign-up locked until … (Guam time)". The rollout page lists Sky under **Locked sign-ups**. Choose **Unlock sign-up**: "Sign-up unlocked." | ☐ Pass ☐ Fail | |
| A5.10 | Desktop | **Resend invite** for Robin Lantern before Robin signs up (or for any unused invite). | A new email arrives. The old link stops working (checked in D4.1). | ☐ Pass ☐ Fail | |
| A5.11 | Desktop | If any sign-up is stuck half done, **Reset sign-up** with a reason. | The unfinished sign-up is cleared and a new invite issued. The rollout page's **Sign-up resets to finish** empties. If nothing is stuck, mark Pending. | ☐ Pass ☐ Fail | |

### A6. Former employee and rehire (staff side)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A6.1 | Desktop [critical] | After Avery Sprig has signed up (C2.4), open Avery's record and **Terminate employee** with today's date. | The **Employee app** panel shows **Former**. The rollout page counts Avery under **Former**. | ☐ Pass ☐ Fail | |
| A6.2 | Desktop | After C15, **Reactivate employee** for Avery. | Avery is active again. The panel shows **Not invited**: nothing is sent automatically. | ☐ Pass ☐ Fail | |
| A6.3 | Desktop | **Invite** Avery again by **Printed code**. | A new sheet prints. Used in C16. | ☐ Pass ☐ Fail | |

### A7. Revoke

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A7.1 | Desktop [critical] | While Sky Lark is signed in on a phone (C17), open Sky's record → **Revoke access**, with a reason. | "App access revoked." Status **Revoked**. | ☐ Pass ☐ Fail | |

### A8. Sign in as (view only) and the support log

Needs the support-view permission on your staff login. It works in production only with two-step sign-in on and the RLS guard in `raise` mode, so it's Pending in an early pass 1.

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A8.1 | Desktop [critical] | Client settings → **Sign in as**. Choose **Client portal**, pick Maren Fable, enter a reason, **Start view-only session**. | A fresh second-step check, then Maren's client portal with a "View only" banner and an **End** button. It says the session lasts up to 30 minutes and the client can see it in their support log. | ☐ Pass ☐ Fail | |
| A8.2 | Desktop [critical] | In that session try to save anything (edit a contact on **Contact Details**, approve a change). | Refused. Nothing changes. | ☐ Pass ☐ Fail | |
| A8.3 | Desktop | Choose **End**. | Back on your own staff view. | ☐ Pass ☐ Fail | |
| A8.4 | Desktop | Start **Sign in as** with **Employee app** for a demo employee. | Today the code opens employee views only for live companies (`api/app/models/view_as_grant.rb:59-60`), so on the demo this option is unavailable or refused. Write what you see. The real check is go-live step 3 on the pilot. | ☐ Pass ☐ Fail | |
| A8.5 | Desktop | Try **Sign in as** on another Cornerstone staff user. | Staff users aren't offered as targets. | ☐ Pass ☐ Fail | |
| A8.6 | Desktop | Leave a session open past 30 minutes. | It ends on its own; the next page load refuses the grant. | ☐ Pass ☐ Fail | |

### A9. The switch

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| A9.1 | Desktop [critical] | Open the switch screen (M4-9d) for the Kitchen. | It lists every readiness check by name with its state: two-step sign-in, RLS guard, Clerk authorized parties and the subdomain, the employee service's health, and counsel text for any terms or consent screen shown. `bank_requests` is locked. | ☐ Pass ☐ Fail | |
| A9.2 | Both [critical] | Turn `employee_portal_enabled` off for the Kitchen. Wait a minute. Reload the app on a signed-in phone. | The phone shows **"The employee app isn't available right now"**. The rollout page says "The employee app isn't turned on for this company yet." | ☐ Pass ☐ Fail | |
| A9.3 | Both | Turn it back on. | The phone works again with no new invite or sign-up. | ☐ Pass ☐ Fail | |

---

## B. Client manager and client user (client portal)

Sign in to the Payroll site as **Maren Fable** (client manager), with the authenticator code. Rows marked "as Tessa" use **Tessa Vale** (client user).

There's one `client` role on main, with no separate manager tier, so the two personas have the same rights for most actions (demo plan §3). Where a row says "manager only", record what Tessa can actually do; it passes only once the planned permission exists.

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| B1 | Both · Agent OK | Sign in as Maren. | The second step is required. The **Dashboard** shows Harbor Finch Kitchen only. Nothing marks it as a demo. | ☐ Pass ☐ Fail | |
| B2 | Desktop · Agent OK | Open **Pay Periods** and the latest committed period. | Maren can review the payroll and its stubs, as a live client can. | ☐ Pass ☐ Fail | |
| B3 | Both · Agent OK | Open **Contact Details**. Turn on **Needs contact details**. | Only employees missing an email, mobile or address are shown, with the missing fields named. Values aren't cut off. | ☐ Pass ☐ Fail | |
| B4 | Desktop | **Edit** a row: add a mobile (7 digits, no area code) and save. | Saved, with a Guam (+1 671) number formatted. | ☐ Pass ☐ Fail | |
| B5 | Desktop | Enter another employee's existing email on a second employee. | A warning, not a block: "Another employee uses this email. Email invites need a unique address." | ☐ Pass ☐ Fail | |
| B6 | Desktop | Enter a placeholder address (for example one on the known placeholder list) or Tessa's login email on an employee. | Blocked ("Not a real email" or the login-email message). | ☐ Pass ☐ Fail | |
| B7 | Both · Agent OK | Open **Employee app**. | The same rollout page as A5.1, without **Sign-up resets to finish**, and with a **Review employee changes** link. | ☐ Pass ☐ Fail | |
| B8 | Desktop | Invite one employee by email and create one printed code from **Invite a group**. | Both work as in A5.3–A5.4. | ☐ Pass ☐ Fail | |
| B9 | Desktop | Open a locked or invited employee's **Employee app** panel. | Maren sees **Invite** and **Resend invite**, but not **Unlock sign-up**, **Revoke access** or **Reset sign-up**. A locked record says "Ask Cornerstone if this employee needs help unlocking sign-up." | ☐ Pass ☐ Fail | |
| B10 | Both | Open **Change Requests** → **Employee changes**, then an employee-submitted address request (from C11). **Approve address**. | A readable before-and-after. "Address approved and updated on the employee record." The employee sees it in C11.4. | ☐ Pass ☐ Fail | |
| B11 | Desktop | **Reject request** on a second address request, with a review note. | "Address request rejected." The current address stays. | ☐ Pass ☐ Fail | |
| B12 | Desktop [critical] | Open Maren's own address request (from C3.4). | No **Approve** button: "Another administrator or Cornerstone must review this request." | ☐ Pass ☐ Fail | |
| B13 | Desktop | As Tessa, approve Maren's address request. | Approved. (If only Cornerstone should approve it at the pilot, record that Tessa could.) | ☐ Pass ☐ Fail | |
| B14 | Desktop | Open **Contact changes** under **Change Requests**. | Contact changes employees made in section C are listed. | ☐ Pass ☐ Fail | |
| B15 | Desktop | Open **Employee app settings**. Change the accent color, upload a square PNG logo under 1 MB. **Save changes**. | "Saved. Employees see the new look the next time they open the app." The preview shows the change before saving. A file over 1 MB is refused. | ☐ Pass ☐ Fail | |
| B16 | Desktop | In **Help contacts**, edit a contact, **Add another contact**, then save. | "Help contacts saved." The phone's **Help** tab shows them in that order (C14). | ☐ Pass ☐ Fail | |
| B17 | Desktop | Remove all Help contacts and save (put them back afterwards). | "Help contacts removed. Employees see the fallback message." Admins see "Help contacts not set up". | ☐ Pass ☐ Fail | |
| B18 | Desktop · Agent OK | Open **Support access**. | Each Sign in as session from A8 is listed with when, who (staff) and the target. Internal staff audit entries aren't shown. | ☐ Pass ☐ Fail | |
| B19 | Desktop | As Tessa: repeat B7–B10 and note which actions work. | Record actual rights. "Manager only" actions pass only once the manager permission exists. | ☐ Pass ☐ Fail | |
| B20 | Desktop [critical] | As Tessa, change the URL to another company's ID or open a direct link to another company's employee. | Not found. No data from another company. | ☐ Pass ☐ Fail | |

---

## C. Employee, on a phone

Use the phone's normal browser. Use the persona named in each row. Unless it says so, use `https://harborfinch.shimizu-technology.com`.

### C1. Sign up from an email invite (Robin Lantern)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C1.1 | Phone [critical] | Open the invite email on the phone and tap its link. | The Harbor Finch Kitchen sign-in page opens, with its name, logo and colors. **Set up your account**, **Step 1 of 2**. | ☐ Pass ☐ Fail | |
| C1.2 | Phone [critical] | Enter Robin's date of birth and SSN last 4. **Continue**. | **Step 2 of 2**, **Your email**. | ☐ Pass ☐ Fail | |
| C1.3 | Phone | Enter Robin's persona email. Leave **Send my pay stub notices to this email** ticked. Tick the Terms checkbox if shown. **Create account**. | "Next you'll choose a password, or use Google or an emailed code." The sign-up form opens. | ☐ Pass ☐ Fail | |
| C1.4 | Phone [critical] | Choose a password and enter the emailed code. | Robin lands on **Home** with **Latest pay**. No two-step prompt (employee-only logins don't need one). | ☐ Pass ☐ Fail | |
| C1.5 | Phone | Add the site to the Home Screen. | The icon and its label show the company's name. | ☐ Pass ☐ Fail | |

### C2. Sign up with a printed code, lockout and unlock (Sky Lark, Avery Sprig)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C2.1 | Phone | Open the address on Sky's printed sheet. **Set up your account**. | **Sign-up code** field: "The 10-letter code on the sheet from your manager." | ☐ Pass ☐ Fail | |
| C2.2 | Phone [critical] | Enter Sky's code with a **wrong** date of birth five times. | The same generic message each time: "Check them and try again. After too many tries, sign-up pauses for 24 hours…". It never says which part was wrong. After the fifth, sign-up is paused. | ☐ Pass ☐ Fail | |
| C2.3 | Phone [critical] | After the Cornerstone admin unlocks it (A5.9), enter the right details. | Step 2 opens. Finish with a persona email and an emailed code instead of a password. Sky lands on **Home**. | ☐ Pass ☐ Fail | |
| C2.4 | Phone | Sign up Avery Sprig with Avery's printed code. | Avery lands on **Home**. | ☐ Pass ☐ Fail | |

### C3. Claim with an existing login (Maren Fable)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C3.1 | Desktop | A Cornerstone admin invites Maren's employee record by email. The panel asks to confirm the payroll login is the same person. | The invite is sent only after the confirmation box is ticked. | ☐ Pass ☐ Fail | |
| C3.2 | Phone [critical] | Open the invite on the phone. Choose **Already have an account? Sign in**, sign in with Maren's client login and the authenticator code. | **Add your employee access**. | ☐ Pass ☐ Fail | |
| C3.3 | Phone [critical] | Enter date of birth and SSN last 4, confirm it's you, **Add access**. | Maren's employee **Home**. The client portal login still works on the Payroll site. | ☐ Pass ☐ Fail | |
| C3.4 | Phone | On **My info**, **Request a change** to the home address. | The request is pending. In the client portal it needs another admin (B12–B13). | ☐ Pass ☐ Fail | |
| C3.5 | Phone | Sign out. Sign in on the employee site with only the password (no authenticator code). | The app shows **Complete two-step sign-in**: Maren is a manager, so the second step is required on the employee site too. | ☐ Pass ☐ Fail | |

### C4. Two employers (Kit Wren)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C4.1 | Phone | Sign up from the Kitchen invite. Then open the Catering invite and sign in with the same login to add access. | One login, two employers. | ☐ Pass ☐ Fail | |
| C4.2 | Phone [critical] | On the **Kitchen** address, sign in. | Only Kitchen pay. No picker: each address shows only its own employer. | ☐ Pass ☐ Fail | |
| C4.3 | Phone [critical] | On the **Catering** address, sign in. | Only Catering pay, with Catering branding. | ☐ Pass ☐ Fail | |
| C4.4 | Phone | Only if a shared employee address (not a client's own) is in use: sign in there. Otherwise mark Pending. | **Choose an employer**: "Which job do you want to see?" Each choice shows only that employer's pay. **Switch employer** on **My info** goes back to the picker. | ☐ Pass ☐ Fail | |

### C5–C7. Home, Pay and the PDF (Robin Lantern; repeat on Rowan Drift and Ellis Quill)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C5.1 | Phone | Open **Home**. | **Latest pay** leads with **Take-home pay**, its payment status and **View pay stub**. **Next payday** shows only when a real upcoming date exists. | ☐ Pass ☐ Fail | |
| C5.2 | Phone | Tap **Hide amounts**. Reload. | Amounts stay hidden on this device until **Show amounts**. The first time, one line explains it. | ☐ Pass ☐ Fail | |
| C6.1 | Phone | Open **Pay**. | The latest check first, then the three most recent, then **View all**. Hours on every row. | ☐ Pass ☐ Fail | |
| C6.2 | Phone [critical] | Open a check. | Earnings with hours × rate, tips on their own line (Rowan), taxes (never labeled "Federal"), deductions, **Take-home pay (net pay)**, **This year so far**. A line compares it with the previous check when it can. | ☐ Pass ☐ Fail | |
| C6.3 | Phone | Compare the stub with the staff stub from A1.4. | Every figure matches to the cent. | ☐ Pass ☐ Fail | |
| C7.1 | Phone [critical] | **Download PDF**. | The PDF opens. It matches the staff stub, shows the SSN as the last 4 only, and prints "Direct deposit" or "Check #…", never "transfer not confirmed". | ☐ Pass ☐ Fail | |
| C7.2 | Phone | Turn on airplane mode and try **Download PDF**. | "You're offline. Connect to download the PDF." No pay is shown from the phone's storage. | ☐ Pass ☐ Fail | |
| C7.3 | Phone | Drew Flint: open the corrected check from A1.7. | The new stub is marked **Corrected**. The original is shown as replaced. | ☐ Pass ☐ Fail | |
| C7.4 | Phone | Quinn Sable: open **Pay** → **All pay stubs**. | Checks from before and after the rehire, in one list. | ☐ Pass ☐ Fail | |

### C8. QuickBooks history (Rowan Drift)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C8.1 | Phone | Open **Pay** → **All pay stubs** and scroll to January–July. | Those checks are under **From QuickBooks records**: "Checks paid before this app started." | ☐ Pass ☐ Fail | |
| C8.2 | Phone | Open the check posted in A3.3. **View original stub (PDF)**. | The original opens. Other QuickBooks checks have no "View original" link and say nothing about it. | ☐ Pass ☐ Fail | |
| C8.3 | Phone [critical] | As Robin, look for Rowan's original. | Not there. Robin sees only Robin's checks. | ☐ Pass ☐ Fail | |

### C9. W-2 (after A2.5)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C9.1 | Phone | Open **Taxes** (**Tax forms** on desktop). | The 2026 W-2GU with **Download W-2GU (PDF)**. "Your paper copy is mailed to your home address." | ☐ Pass ☐ Fail | |
| C9.2 | Phone | Download it. | Copy B and C, SSN truncated. | ☐ Pass ☐ Fail | |
| C9.3 | Phone | As Drew Flint (after A2.6). | "A corrected form is being prepared." No PDF. | ☐ Pass ☐ Fail | |
| C9.4 | Phone | Check the persona inbox for the W-2 notice. | Subject "IMPORTANT TAX RETURN DOCUMENT AVAILABLE". The employer's name and a link to the app. No amount, no SSN. (Only if `PORTAL_EMAIL_NOTIFICATIONS_ENABLED` is on and the address is verified; otherwise mark Pending.) | ☐ Pass ☐ Fail | |

### C10–C12. My info: contact changes with step-up, address request, emergency contacts

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C10.1 | Phone [critical] | As Robin, **My info** → **Change mobile phone**, enter a new number, **Save phone**. | If Robin signed in more than 10 minutes ago, a "confirm it's you" step comes first (password or emailed code). Then "Phone number saved." | ☐ Pass ☐ Fail | |
| C10.2 | Phone | **Change personal email** to Robin's second persona alias, **Send code**, enter the code, **Confirm email**. | "Email verified and saved." A verified badge shows. | ☐ Pass ☐ Fail | |
| C10.3 | Phone | Cancel a confirm-it's-you prompt. | "Not saved…" and nothing changes. | ☐ Pass ☐ Fail | |
| C10.4 | Phone | (Optional) as a persona who enrolled an authenticator, change the phone. | The confirm step uses the authenticator. | ☐ Pass ☐ Fail | |
| C11.1 | Phone | As Robin, **Home address** → **Request a change**. Enter a new address, **Send request**. | The current and requested address side by side, with **Edit request** and **Cancel request**. "{Company} checks the new address before it's used." | ☐ Pass ☐ Fail | |
| C11.2 | Phone | **Edit request**, change the ZIP, save. Then try another change while it's pending. | "Request updated." A second request isn't possible while one is pending. | ☐ Pass ☐ Fail | |
| C11.3 | Phone | As Sky Lark, send an address request and **Cancel request**. | "Request cancelled." | ☐ Pass ☐ Fail | |
| C11.4 | Phone | After B10 approves Robin's request, reload **My info**. | "Your new address was approved." The address is updated. "Your W-2 will be mailed here." | ☐ Pass ☐ Fail | |
| C11.5 | Phone | Try to edit **Legal name** or **Social Security number**. | Not editable. "Contact Cornerstone" with what to bring. | ☐ Pass ☐ Fail | |
| C12.1 | Phone | **Emergency contacts** → **Add a contact**. Fill name, relationship, phone. **Save & add another**. | "{Name} saved. Add another contact." The form clears for the next one. | ☐ Pass ☐ Fail | |
| C12.2 | Phone | Edit one, then **Remove** one (confirm). | Both work. Up to five contacts. | ☐ Pass ☐ Fail | |

### C13. Electronic delivery consent and withdrawal

Only if `delivery_consent` is on for the demo. The demo uses the draft wording.

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C13.1 | Phone | **My info** → **Electronic pay statements**. Read the disclosure, tick "I have read this disclosure and agree…", confirm it's you. | **Electronic consent on file**. Paper still continues during the pilot. | ☐ Pass ☐ Fail | |
| C13.2 | Phone | **Electronic Form W-2GU** → **Open test PDF**. Enter a wrong code, then the 6-character code from inside the PDF. | The wrong code is refused. The right one records consent. | ☐ Pass ☐ Fail | |
| C13.3 | Phone | **Switch back to paper (withdraw consent)** → **Confirm paper delivery**. | One tap, no step-up. "Saved. You'll get paper copies." Status **Paper delivery (withdrawn)**. A **Delivery consent** row appears on **Changes to confirm** (A4.2). | ☐ Pass ☐ Fail | |
| C13.4 | Phone | As an employee, look for "Draft wording". | Not shown to employees (it shows only to staff). | ☐ Pass ☐ Fail | |

### C14. Help

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C14.1 | Phone | Open **Help**. | "Questions about your pay or this app? These people can help." The client's contacts with tap-to-call and email. **Common questions**. **Terms and privacy** links if terms are configured. | ☐ Pass ☐ Fail | |
| C14.2 | Phone | After B17 removes the contacts, reload **Help**. | "Ask your manager at Harbor Finch Kitchen", plus the company's main phone if set. No Cornerstone fallback. | ☐ Pass ☐ Fail | |
| C14.3 | Phone | Sign out. On the sign-in screen open **Can't sign in?** | The same "ask your manager" wording, and how to use **Forgot password?**. No named contacts before sign-in. | ☐ Pass ☐ Fail | |

### C15. Former employee (Avery Sprig, after A6.1)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C15.1 | Phone [critical] | Sign in as Avery. | "You're viewing your past pay". Pay stubs and tax forms are read-only. **Next payday** never shows. | ☐ Pass ☐ Fail | |
| C15.2 | Phone [critical] | Try to change the phone or request an address change. | Not offered, or refused. | ☐ Pass ☐ Fail | |
| C15.3 | Phone | Open **Taxes**. | "Your paper copy is mailed to your last address on file." | ☐ Pass ☐ Fail | |

### C16. Rehire (Avery Sprig, after A6.3)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C16.1 | Phone | Open the new printed code, enter it with date of birth and SSN last 4. | "Welcome back" and **Turn my account back on**: the same login, no second account. | ☐ Pass ☐ Fail | |
| C16.2 | Phone | Sign in fresh and finish. | Avery's earlier stubs and any new ones are in one list. Old sessions from before termination don't work. | ☐ Pass ☐ Fail | |

### C17. Revoke ends the session (Sky Lark)

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C17.1 | Phone [critical] | With Sky signed in, the Cornerstone admin revokes (A7.1). Tap any tab. | **"Your access has ended"**. Signing in again doesn't bring back pay. | ☐ Pass ☐ Fail | |

### C18. Desktop

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| C18.1 | Desktop | Sign in as Robin on a laptop. | A top navigation bar and a two-column **Home**. | ☐ Pass ☐ Fail | |
| C18.2 | Desktop | Open **Pay**. | The list on the left, the stub on the right, with **Previous** and **Next**. | ☐ Pass ☐ Fail | |
| C18.3 | Desktop | Open a new browser profile and sign in as Robin. | Clerk emails a code to check the new device. | ☐ Pass ☐ Fail | |

---

## D. Negative tests

Every failure must look the same to the person trying, and never say whether an employee or account exists.

| # | Device | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| D1.1 | Phone [critical] | **Wrong company:** open Morgan Tide's Catering invite link on the **Kitchen** address (swap the host in the link). | The generic "couldn't finish" message. No Catering data on the Kitchen address. | ☐ Pass ☐ Fail | |
| D1.2 | Phone [critical] | **Wrong company:** sign in as Robin (Kitchen only) on the **Catering** address. | "The employee app isn't available right now" or "Your access has ended". Never Robin's Kitchen pay. | ☐ Pass ☐ Fail | |
| D1.3 | Agent OK [critical] | **Wrong company (API):** signed in as Kit on the Kitchen address, send a request with the Catering link's `X-Employee-Link-Id`. | 404. | ☐ Pass ☐ Fail | |
| D2.1 | Phone [critical] | **Wrong person:** use Sky's printed code with Robin's date of birth and SSN last 4. | The same generic message as any wrong detail. | ☐ Pass ☐ Fail | |
| D2.2 | Agent OK [critical] | **Wrong person (API):** as Robin, request another employee's statement ID, PDF or tax form ID. | 404 for each, the same as an ID that doesn't exist. | ☐ Pass ☐ Fail | |
| D2.3 | Phone | **Wrong person:** forward Robin's invite email to Kit; Kit opens it and uses Kit's own date of birth. | Refused with the generic message. | ☐ Pass ☐ Fail | |
| D3.1 | Desktop [critical] | **View-only can't write:** in a Sign in as session (A8), try a save, an approval and an invite. | Every one is refused. Nothing changes. No notice is sent. | ☐ Pass ☐ Fail | |
| D3.2 | Phone [critical] | **View-only can't write:** former employee Avery tries a change (C15.2). | Refused. | ☐ Pass ☐ Fail | |
| D3.3 | Desktop | **Client can't do staff actions:** as Tessa, call unlock, revoke or reset sign-up (if the buttons are hidden, try from the API). | Refused. | ☐ Pass ☐ Fail | |
| D3.4 | Desktop [critical] | **Employee-only login on the staff site:** sign in as Robin on the Payroll site. | No staff or client pages. | ☐ Pass ☐ Fail | |
| D4.1 | Phone [critical] | **Replaced invite:** after A5.10, open Robin's **old** invite link. | Refused with the generic message. The new link works. | ☐ Pass ☐ Fail | |
| D4.2 | Phone [critical] | **Expired invite:** 14 days after A5.5, open Ellis Quill's unused invite. Before day 14, mark Pending. | Refused with the generic message. The rollout page lists Ellis under **Expiring or expired invites** ("Expired …"). A **Resend invite** works. | ☐ Pass ☐ Fail | |
| D4.3 | Phone | **Used code:** after C2.4, try Avery's first printed code again. | Refused. | ☐ Pass ☐ Fail | |
| D5.1 | Agent OK | **Unknown address:** request branding for a host that isn't registered (platform runbook §3.5). | 404, no CORS header. | ☐ Pass ☐ Fail | |
| D5.2 | Phone | **Switch off:** A9.2. | "The employee app isn't available right now". | ☐ Pass ☐ Fail | |
| D6.1 | Lead | **Shared Wi-Fi:** have 5 phones on one Wi-Fi sign in and download a PDF at the same time. | No "Too many tries, wait a minute" for normal use. | ☐ Pass ☐ Fail | |

---

## E. After the run

| # | Who | Step | Expected | Pass/Fail | Notes |
|---|---|---|---|---|---|
| E1 | Lead | Compare the firm's client counts, KPIs, profitability and billing with before the run. | Unchanged. | ☐ Pass ☐ Fail | |
| E2 | Lead | Check outbound logs: email and Clerk invitations. | Only allow-listed persona addresses. One blocked outside address was refused with no send request. | ☐ Pass ☐ Fail | |
| E3 | Lead | Check filing, AIRE and Cornerstone Tax logs. | No transmission, no AIRE or Tax activity for the demo. | ☐ Pass ☐ Fail | |
| E4 | Lead | Check the employee service logs for the run window. | No 5xx and no RLS guard errors. | ☐ Pass ☐ Fail | |
| E5 | Cornerstone admin | Revoke the disposable sign-ups the next run needs fresh (keep Kit, Maren and one employee active for training). | Revoked. | ☐ Pass ☐ Fail | |

### Sign-off

| Field | Value |
|---|---|
| Rows passed / failed / pending | |
| Issues raised (IDs) | |
| Tester's verdict (accept / accept with issues / reject) | |
| Signed off by (role) and date | |
