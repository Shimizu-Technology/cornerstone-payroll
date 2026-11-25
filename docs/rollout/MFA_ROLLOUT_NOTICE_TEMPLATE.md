# Two-step sign-in notices (templates)

Two-step sign-in is required for everyone once it's turned on: Cornerstone staff, client users and employees. Send each group its version at least 48 hours before the switch. See [MFA_ROLLOUT_RUNBOOK.md](MFA_ROLLOUT_RUNBOOK.md).

- **Version A** goes to Cornerstone staff and client users (and dual-role users).
- **Version B** goes to employees of each company whose employee app is on, through that company's usual channel (or the employee app's email), with the company's name in it.

Replace every `[PLACEHOLDER]`. Keep it as plain text so it reads well on a phone. Before sending, open the account link on a test account and check that it works (runbook, Step 5).

---

## Version A: staff and client users

**Subject:** Action needed by [DATE]: set up two-step sign-in for Cornerstone Payroll

Hi [FIRST NAME],

On **[DATE]** we're adding a second step to signing in to Cornerstone Payroll. After your password (or Google sign-in), you'll enter a 6-digit code from an app on your phone.

**Why:** Payroll holds pay, bank and tax details. A password alone isn't enough to protect that. The second step stops someone who has only your password.

**What you need:** your phone, and about 5 minutes. You can do this today. You don't have to wait until [DATE].

### Set it up

**1. Get an authenticator app** (free) on your phone, if you don't have one. Any of these works: Google Authenticator, Microsoft Authenticator, Authy, 1Password, or the one built into your password manager. Not sure? Install Google Authenticator.

**2. Open your account settings.** Sign in to Cornerstone Payroll as you do today, then open **Account & security**. Or go straight to:
[ACCOUNT LINK]

**3. Find the security section.** Tap **Security**, then **Two-step verification** (or **Add two-step verification**), then **Authenticator app**.

**4. Scan the code.** A square code (QR code) appears. In your authenticator app, tap **+** or **Add**, choose **Scan a QR code**, and point your phone at the screen. On a single phone, tap **"Can't scan?"** to copy a setup key into the app instead.

**5. Type the 6-digit code.** Your app now shows a 6-digit number that changes every 30 seconds. Type the current one into the box and tap **Continue**.

**6. Save your backup codes. Don't skip this.** You'll see a list of backup codes. Each works once if you ever lose your phone. Do one of these now:
- Save them in your password manager, or
- Write them down and keep them somewhere safe, **not** on the phone you use for the app.

Tap **Finish**.

**7. Try it.** Sign out, then sign in again. Enter your password (or use Google), then the 6-digit code from the app. If you get in, you're done.

### What changes after [DATE]

- Each time you sign in on a new browser or after you sign out, you'll enter a code from your app.
- If you haven't set it up yet, sign-in will ask you to set it up before you continue: follow steps 3 to 6 above. If you see a screen titled **"Multi-factor authentication required"** instead, tap **Open account settings**, do the same, then **sign out and sign in again**.
- Before some changes (like turning on a company's employee app), you'll be asked for a fresh code from your app.
- If you open Payroll with an old sign-in that predates [DATE], you may see that screen on your next click. Anything you hadn't saved may be lost, so save your work before then.

### If something goes wrong

- **Lost or new phone:** sign in with your password, choose **Use another method**, and enter one backup code. Then set up the new phone and make new backup codes.
- **No backup codes and no phone:** contact us. We'll check it's really you and reset your two-step sign-in so you can set it up again.
- **The code is "wrong":** check that your phone's clock is set to automatic. Codes last 30 seconds, so try the next one.
- **Anything else:** contact **[SUPPORT NAME]** at **[SUPPORT EMAIL OR PHONE]**, **[SUPPORT HOURS, e.g. weekends included during [DATE]]**.

We will never ask you for your 6-digit code or backup codes by text, email or phone. If someone does, don't share them and tell us.

Thank you for helping keep everyone's pay information safe.

[SENDER NAME]
[ROLE], [ORGANIZATION]

---

## Version B: employees

**Subject:** Set up a second sign-in step for your [COMPANY NAME] pay app by [DATE]

Hi [FIRST NAME],

On **[DATE]**, the app where you see your pay stubs and tax forms from **[COMPANY NAME]** will ask for a second step when you sign in: a 6-digit code from an app on your phone, after your password, Google or emailed code.

**Why:** your pay stubs and W-2 show private details. The code stops someone who only has your password.

**What you need:** your phone, and about 5 minutes. You can do it today.

**1. Get a free authenticator app** if you don't have one, for example Google Authenticator or Microsoft Authenticator.

**2. In the pay app,** sign in as usual, then tap **My info**, then **Sign-in & security**.

**3. Tap Security, then Two-step verification, then Authenticator app.**

**4. Scan the square code** with your authenticator app (tap **+** or **Add**, then **Scan a QR code**). If you're using only one phone, tap **"Can't scan?"** and copy the setup key into the app instead.

**5. Type the 6-digit code** the app shows, then tap **Continue**.

**6. Save your backup codes.** Each one works once if you lose your phone. Write them down and keep them somewhere safe, not only on this phone.

**After [DATE]:** each time you sign in on a new phone or after signing out, enter the code from your app. If you haven't set it up, the app will ask you to before it shows your pay. Before you change your phone number, email, address or how you get your pay stubs, you'll be asked for a fresh code.

**Lost your phone?** Sign in, choose **Use another method**, and enter a backup code. No backup codes? Ask **[MANAGER OR CONTACT AT COMPANY]**. They'll get Cornerstone to check it's really you and reset it.

We will never ask for your code or backup codes by text, email or phone. If someone does, don't share them.

[SENDER NAME], [COMPANY NAME]

---

## Notes for the sender

- **Staff and client users** get Version A. **Dual-role users** (staff or client who also have an employee login) get Version A too; one setup covers both sites.
- **Employees** get Version B, company by company. Tell each company's managers first so they can answer questions.
- Add the same two or three lines to the sign-in invitation email for people invited after [DATE] ("you'll set up two-step sign-in before your first visit").
- Send a shorter reminder the day before: "Tomorrow, [DATE], Payroll will ask for a code from your authenticator app. Set it up now: [ACCOUNT LINK]." For employees: "Tomorrow, [DATE], the pay app will ask for a code from your authenticator app. Set it up now in My info → Sign-in & security."
- Don't schedule a payroll cutoff or print run for the hour of the switch.
