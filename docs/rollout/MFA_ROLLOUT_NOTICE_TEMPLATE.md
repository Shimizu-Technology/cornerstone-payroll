# Two-step sign-in notice (template)

Send to Cornerstone staff and client users at least 48 hours before the switch. Do **not** send to employee-only users; nothing changes for them. See [MFA_ROLLOUT_RUNBOOK.md](MFA_ROLLOUT_RUNBOOK.md).

Replace every `[PLACEHOLDER]`. Keep it as plain text so it reads well on a phone. Before sending, open the account link on a test account and check that it works (runbook, Step 5).

---

**Subject:** Action needed by [DATE]: set up two-step sign-in for Cornerstone Payroll

Hi [FIRST NAME],

On **[DATE]** we're adding a second step to signing in to Cornerstone Payroll. After your password (or Google sign-in), you'll enter a 6-digit code from an app on your phone.

**Why:** Payroll holds pay, bank and tax details. A password alone isn't enough to protect that. The second step stops someone who has only your password.

**What you need:** your phone, and about 5 minutes. You can do this today. You don't have to wait until [DATE].

### Set it up

**1. Get an authenticator app** (free) on your phone, if you don't have one. Any of these works: Google Authenticator, Microsoft Authenticator, Authy, 1Password, or the one built into your password manager. Not sure? Install Google Authenticator.

**2. Open your account settings.** On your phone or computer, go to:
[ACCOUNT LINK]
Sign in with your usual password or Google, as you do today.

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
- If you haven't set it up yet, you'll see a screen titled **"Multi-factor authentication required."** Tap **Open account settings**, follow steps 3 to 6 above, then **sign out and sign in again**. You'll be in.
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

## Notes for the sender

- **Staff and client users** get this notice. **Dual-role users** (staff or client who also have an employee login) get it too, since they are required.
- Add the same two or three lines to the sign-in invitation email for people invited after [DATE] ("you'll set up two-step sign-in before your first visit").
- Send a shorter reminder the day before: "Tomorrow, [DATE], Payroll will ask for a code from your authenticator app. Set it up now: [ACCOUNT LINK]."
- Don't schedule a payroll cutoff or print run for the hour of the switch.
