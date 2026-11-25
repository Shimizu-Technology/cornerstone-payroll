# Guam Workforce Platform: Legal Compliance Research Brief

Prepared 2026-11-19 for Shimizu Technology and Cornerstone Accounting (updated the same day with how Cornerstone works today, Part 5, and revised question lists, Parts 3–4), as background for a later review by a law firm. **This is research, not legal advice.** Statutes are quoted from the Guam Compiler of Laws texts and federal sources read during this research. Anything a lawyer or agency must confirm is marked.

**Confidence labels used throughout**

- **[Confirmed]**: I read the primary source text (statute, regulation, or agency publication) during this research.
- **[Primary, not re-read]**: a primary source I am citing from established knowledge. The URL is given, but I did not open it during this research. Verify before relying on it.
- **[Secondary]**: supported only by law-firm, vendor, or press commentary.
- **[Not found]**: I found no primary source. Guam law may be silent, or the rule may sit in regulations or guidance I could not reach.

Key Guam sources used:

- 22 GCA Chapter 3 (Fair Labor Standards), Compiler edition COL08222024, via Justia's mirror of the Compiler PDF: <https://statecodesfiles.justia.com/guam/2024/title-22/division-1/chapter-3/chapter-3.pdf>
- Guam DOL FLSA Handbook and Poster, rev. Feb 16, 2026: <https://dol.guam.gov/wp-content/uploads/GDOL-FLSA-Handbook-as-of-2.16.2026.pdf>
- 1 GCA Chapter 10 (Holidays), COL 2026-04-23: <https://col.guamcourts.gov/sites/default/files/01gc010.pdf>
- 18 GCA Chapter 91 (Guam UETA): <https://col.guamcourts.gov/sites/default/files/18gc091.pdf>
- 9 GCA Chapter 48 (breach notification): <https://statecodesfiles.justia.com/guam/2024/title-9/chapter-48/chapter-48.pdf>
- 5 GCA Chapter 34, Article 3 (New Hire Directory): <https://statecodesfiles.justia.com/guam/2024/title-5/division-3/chapter-34/chapter-34.pdf>

---

## Part 1. One-page summary: what the product must do

These are build requirements. Each one traces to a section below.

**Pay and pay stubs**

1. Produce a pay statement for every payment. It must show **every deduction** and every sum paid to anyone other than the employee, and it must be available to the employee **at the time of payment** (22 GCA § 3212(a)). Include gross pay, hours by day and week, rate(s), overtime, all additions and deductions, net pay, pay date, and pay period. These items come from the § 3110 and FLSA record lists.
2. Electronic pay stubs need the employee's **recorded agreement** to receive records electronically. They must also be **printable and downloadable**, and no feature may block saving or printing (18 GCA §§ 91105, 91108). Keep a paper option for anyone who declines (§ 91105(c)).
3. **Direct deposit must be voluntary.** It needs a written, signed authorization, a check or cash fallback, and an employee-chosen bank. 22 GCA § 3212(b) says wages "shall be in the form of cash or check." **Do not ship mandatory direct deposit or pay cards until Guam DOL or counsel confirms they are allowed.**
4. Accept a deduction only if a law or court order requires it or the employee authorized it in writing. **Fines may never be deducted** (§§ 3203–3204). Store the signed authorization against each deduction code.
5. Pay-date engine:
   - Wages are due **within 7 days after the pay period ends** (§ 3201).
   - A discharged employee is paid **immediately** (§ 3201(a)).
   - An employee who quits is paid on the **next regular payday** (§ 3201(b)).
   - Block or warn on any schedule that breaks these rules. Give termination a "final pay due now" workflow.
6. When payroll will be late, generate the **§ 3213 statement**. It goes to each employee and to the Director of Labor within 5 working days and shows correct hours, wages, legal deductions, and net payable.
7. Remit withheld amounts that are owed to third parties (child support, loans, benefits) within **5 days after the day the employee's pay is due**. Missing that window counts as "failure to pay wages" (§ 3217(b)).

**Wage and hour rules engine**

8. Minimum wage is **$9.25/hr** (22 GCA § 3105, effective Sept 1, 2021). Guam's rate automatically rises if the federal minimum ever exceeds it (§ 3121).
9. **No tip credit in Guam.** Tipped workers must receive $9.25/hr in cash wages, with tips on top (§ 3104 says "wage… shall not include tips or gratuities"; GDOL poster). Tips belong to employees. Tip pools are allowed. Service charges are employer revenue, and any portion paid to staff is wages that go into the overtime regular rate.
10. Overtime is 1.5× the regular rate for hours over 40 in a workweek (§ 3107(a); FLSA). No comp time in place of overtime for private employers.
11. **Meal period rule.** No work period over **5 hours** without a meal period of at least 30 minutes. The meal may be waived **only** when a work period of 6 hours or less completes the day's work, and only by mutual consent (§ 3107(c)). The time clock must flag violations and store waivers.
12. **Split-shift rule.** All shifts within 24 hours must fall inside **14 consecutive hours**, except in an extraordinary emergency (§ 3107(b)). Scheduling must flag violations.
13. Short rest breaks (about 20 minutes or less) count as paid time. Meal periods are unpaid only if the employee is completely relieved of duty (29 CFR 785.18–785.19).
14. Exemption tests must use the **federal** salary threshold ($684/week) for FLSA-covered employers. The Guam statute's $455/week is lower (§ 3108).

**Leave**

15. Track the Guam leave entitlements:
    - **Guam FMLA**: employers with 20+ employees, 12 workweeks (§§ 3602–3603)
    - **Bereavement**: up to 14 days per 12 months, counted inside the FMLA total (§ 3610)
    - **Child school-related leave**: up to 40 hours per year, 8 per month for planned activities (§ 3703)
    - **Victims-of-violence leave**: reasonable leave, paid or unpaid (§ 3401)
16. Holiday calendar defaults to the 12 Guam holidays in 1 GCA § 1000. Holiday pay is a per-employer **policy setting**. Guam law does not require private employers to give holidays off or pay a premium.

**Onboarding**

17. Electronic **W-4**: show exactly the IRS form content and jurat. Make the e-signature the final entry, authenticate the signer, log every submission, and be able to print a hard copy for the IRS (26 CFR 31.3402(f)(5)-1(c)).
18. Electronic **I-9**:
    - Meet 8 CFR 274a.2(e)–(i): integrity controls, an audit trail of who created, completed, or changed each form, indexing, legible printouts, and signature-attestation capture.
    - Track the Section 2 deadline (3 business days).
    - Support an authorized-representative workflow.
    - Support the E-Verify remote-exam alternative (live video, checkbox, retained copies).
    - Include the FSM/RMI Compact passport + I-94 as a List A option.
19. **New-hire report** to the Guam Child Support Enforcement Division (Office of the Attorney General) within **20 calendar days** of hire or rehire (5 GCA § 34303). The report carries the employee's name, address, SSN, and date of birth, plus the employer's name, address, and EIN. Electronic reporters must transmit **twice a month, 12–16 days apart** (§ 34305(b)).

**Year-end**

20. W-2GU:
    - File Copy A with SSA through Business Services Online (BSO), EFW2 format.
    - Upload Copy 1 to Guam DRT through GuamTax.com. Use a **payroll processor account** and keep **one GuamTax account per client EIN**.
    - Deadline is **Jan 31**. For tax year 2026 (Jan 31, 2027 is a Sunday), DRT's date and weekend rule are **unconfirmed**. Plan to file with DRT by **Friday, Jan 29, 2027** unless DRT confirms Feb 1. The IRS Feb 1, 2027 date covers SSA filing and employee copies only.
    - E-filing is mandatory at **10 or more** combined information returns.
    - DRT copies need **full SSNs**.
    - GuamTax.com does not accept corrections, so build a paper W-2c / W-3cSS path.
21. Electronic W-2GU to employees follows the IRS consent model (26 CFR 31.6051-1(j)):
    - affirmative electronic consent that shows the employee can open the format
    - the required disclosures
    - an email subject line reading "IMPORTANT TAX RETURN DOCUMENT AVAILABLE"
    - a mailed notice within 30 days when an email bounces
    - the form stays online through Oct 15
    - paper within 30 days of a withdrawal of consent
22. 1099s for Guam payers go to DRT through GuamTax.com in IRS Pub 1220 format.

**Security, messaging, and devices**

23. Security baseline (FTC Safeguards Rule, 16 CFR 314.4):
    - MFA for everyone who accesses customer information
    - encryption at rest and in transit
    - access controls and least privilege
    - activity logging and monitoring
    - change management
    - secure development
    - disposal of data within 2 years of last use unless retention is required
    - annual penetration test and vulnerability scans every 6 months
    - written incident response plan
    - a breach-reporting workflow that supports the 30-day FTC notice for 500+ consumers and Guam notice "without unreasonable delay"
24. SMS:
    - Record opt-in consent per employee, per category (pay notices, schedules, and so on).
    - Never send marketing.
    - Honor STOP, QUIT, END, REVOKE, OPT OUT, CANCEL, and UNSUBSCRIBE within 10 business days at most. Aim for immediately.
    - Register brands and campaigns under A2P 10DLC.
    - Under the FCC rules effective **Nov 25, 2026**, informational opt-outs may be scoped to a message category.
25. Geolocation and biometrics:
    - Show a written notice and record an acknowledgment.
    - Capture location **only at punch time**, never continuously. Offer a geofence result rather than raw coordinates where possible.
    - Offer a non-biometric alternative (PIN or badge).
    - For biometrics, store templates, not raw images. Encrypt them, publish a retention schedule, and delete them at separation.

**Records and contracts**

26. Retention: keep payroll records **at least 6 years** (Guam DOL's stated period). See the table in Q5. Include legal-hold and deletion controls.
27. Contracts and policies: a client service agreement, a data processing addendum, employee-app terms, and a privacy notice. Section 12 lists their contents. The employer stays responsible for tax deposits in IRS terms. Cornerstone's AICPA confidentiality duty means the Cornerstone–Shimizu agreement needs confidentiality terms.

---

## Part 2. Findings by question

### Q1. Pay stubs (wage statements)

**Guam rule.**

- 22 GCA § 3212(a): "All deductions taken from an employee's pay by an employer, and all sums payable or paid to the employer from said pay to the employee, shall be shown on the employee's pay statement or check stub, and a copy thereof shall be given to the employee at the time the employee is paid. A copy thereof shall be kept by the employer for three (3) years." **[Confirmed]**
  - Source: <https://statecodesfiles.justia.com/guam/2024/title-22/division-1/chapter-3/chapter-3.pdf>
- The GDOL poster (rev. 02.2026) restates it: employers "must show, on a check stub or pay statement, all deductions taken from an employee's pay, and a copy of it must be given to the employee." **[Confirmed]**
- Guam does not list the full contents of a pay statement in statute. Section 3212 only requires the deductions. The record-keeping list in § 3110 and the GDOL handbook covers name, address, SSN or passport number, occupation, rate of pay and pay period, daily and weekly hours, straight-time and overtime earnings, additions and deductions, total wages, pay date, and period covered. Showing all of these on the stub is the safe design. **[Confirmed]** that these are the required records. **[Not found]**: any Guam rule requiring them on the stub itself.

**Payment form.**

- 22 GCA § 3212(b): "All payments made to an employee by an employer shall be in the form of cash or check." **[Confirmed]**
- I found no Guam provision or GDOL guidance authorizing direct deposit or pay cards. **[Not found]**
- Direct deposit is widely used in Guam, apparently on a voluntary basis. That practice is not legal authority.
- Federal Regulation E bars an employer from requiring employees to receive wages by electronic transfer at a particular institution (12 CFR 1005.10(e)(2)). **[Primary, not re-read]** <https://www.consumerfinance.gov/rules-policy/regulations/1005/10/>

**Electronic delivery.**

- Guam UETA (18 GCA ch. 91, effective Apr 1, 2015) applies only between parties who have agreed to transact electronically. Agreement is judged "from the context and surrounding circumstances, including the parties' conduct" (§ 91105(b)). A party may refuse electronic transactions, and that right cannot be waived (§ 91105(c)). **[Confirmed]**
- When a law requires information to be "provided, sent, or delivered in writing," an electronic record satisfies it only if it is "capable of retention by the recipient at the time of receipt." A record is not capable of retention if the sender "inhibits the ability of the recipient to print or store" it (§ 91108(a)). If the sender inhibits printing or storing, the record "is not enforceable against the recipient" (§ 91108(c)). **[Confirmed]** <https://col.guamcourts.gov/sites/default/files/18gc091.pdf>
- Guam DOL has published nothing specific on electronic pay stubs. **[Not found]**

**Federal baseline.**

- The FLSA requires accurate payroll records but no pay stub. DOL says the Act "requires no particular form for the records." **[Confirmed]** <https://www.dol.gov/agencies/whd/fact-sheets/21-flsa-recordkeeping>
- E-SIGN (15 U.S.C. § 7001) also validates electronic records. Its consumer-consent procedure (§ 7001(c)) applies to "consumers." Employees receiving pay records are probably not consumers under that definition, but the E-SIGN consent pattern is a sound model. **[Primary, not re-read]** <https://www.law.cornell.edu/uscode/text/15/7001>

**What the product should do.**

- Collect an explicit "I agree to receive pay statements and employment records electronically" consent. Record timestamp, account, IP or device, and the version of the disclosure text. Allow withdrawal.
- Publish each stub as a downloadable PDF no later than the pay date and moment of payment. Never disable printing or saving.
- Let a payroll admin flag "paper stub required" for any employee who declines or has no device. The system must then print stubs with the check.
- Show every deduction by name and amount, every employer-paid item withheld from pay, and the § 3110 fields.
- Treat direct deposit as an opt-in with a signed authorization. Keep a check fallback. Hold mandatory direct deposit and pay cards pending confirmation.

---

### Q2. Holidays

**Guam legal holidays (1 GCA § 1000(a), Compiler edition 2026-04-23)** **[Confirmed]** <https://col.guamcourts.gov/sites/default/files/01gc010.pdf>

1. New Year's Day (Jan 1)
2. Martin Luther King, Jr. Day (third Monday in January)
3. Guam History and CHamoru Heritage Day (first Monday in March)
4. Memorial Day (last Monday in May)
5. Independence Day (July 4)
6. Liberation Day (July 21)
7. Labor Day (first Monday in September)
8. All Souls' Day (Nov 2)
9. Veterans' Day (Nov 11)
10. Thanksgiving (fourth Thursday in November)
11. Our Lady of Camarin Day (Dec 8)
12. Christmas (Dec 25)

Other holiday rules in the chapter:

- When a holiday falls on a weekend, the government of Guam follows federal practice (§ 1000(b)).
- The Governor may declare additional one-year holidays by executive order (§ 1000(c)). The calendar therefore needs ad hoc holidays.
- The list was most recently amended by P.L. 38-030 (June 17, 2025).
- Presidents' Day, Columbus Day, and Juneteenth are not Guam holidays under § 1000.

**Must private employers give these days off or pay a premium?**

- I found no Guam statute requiring private employers to close, grant paid holidays, or pay premium rates on legal holidays. **[Not found]**
- Section 1000 defines government holidays. Guam's wage law (22 GCA ch. 3) contains no holiday-pay provision. **[Confirmed]**: no such section exists in ch. 3.
- Federal law: the FLSA does not require pay for time not worked on holidays or premium pay for holiday work, unless the hours push the week over 40. **[Primary, not re-read]** <https://www.dol.gov/general/topic/workhours/holidays>
- Holiday premium pay of at least 1.5× may be excluded from the regular rate and credited toward overtime (29 U.S.C. § 207(e)(6), (h)(2)). **[Primary, not re-read]**

**What the product should do.** Ship the 12 Guam holidays as a default calendar with an "add one-time holiday" option for executive orders. Each employer configures which holidays are paid, the premium multiplier, and eligibility. Handle holiday premium correctly in the regular-rate calculation.

---

### Q3. Meal and rest breaks

**Guam rules (22 GCA § 3107)** **[Confirmed]**

- **Meal period** (§ 3107(c)): "No employer shall employ any employee for a work period of more than five (5) hours without a meal period of not less than thirty (30) minutes; except that when a work period of not more than six (6) hours will complete the day's work, the meal period may be waived by mutual consent of employer and employee. Meal period shall not be considered 'on duty' or counted as time worked, unless the nature of his work prevents an employee from being relieved of duty."
- **GDOL's reading** (poster): an employee "scheduled to work a period of 5 (five) hours or more, must be provided an unpaid and uninterrupted meal period." The statute says "more than five" hours. The poster says "5 hours or more." The safe build triggers at 5:00. **[Confirmed]**
- **Split shifts** (§ 3107(b)): "No employer shall employ any employee in split shifts unless all of the shifts within a period of twenty-four (24) hours fall within a period of fourteen (14) consecutive hours, except in case of extraordinary emergency."
- **Rest breaks:** Guam has no rest-break mandate. **[Not found]**
- **How to record waivers:** the statute requires only "mutual consent" and sets no form. **[Not found]**: any GDOL form or rule. The GDOL handbook says Guam applies the federal FLSA Field Operations Handbook where it does not conflict with Guam law (§ 3116).

**Federal (FLSA)**

- Short rest periods "usually 20 minutes or less" are hours worked and must be paid.
- Bona fide meal periods "typically 30 minutes or more" are unpaid only if the employee is "completely relieved from duty."
- Unauthorized extensions of a break need not be paid if the employer clearly communicated the limit.
- Work "suffered or permitted" must be paid.
- **[Confirmed]** <https://www.dol.gov/agencies/whd/fact-sheets/22-flsa-hours-worked>; 29 CFR 785.18–785.19.

**What the product should do.**

- **Meal-period monitor.** Warn before and flag after any work segment over 5 hours with no recorded 30-minute meal. Short meals under 30 minutes are flagged and paid as work time by default.
- **Waiver capture.**
  - Store a standing signed waiver per employee. It must be revocable and state that it applies only when the day's work is 6 hours or less.
  - Also store a per-shift confirmation at clock-out ("I waived my meal break today by agreement").
  - Reject a waiver on any shift over 6 hours.
- **On-duty meals.** If the employee was not relieved of duty, count the meal as paid time. Provide an "on-duty meal" punch type.
- **Split-shift check.** On schedules and actual punches, flag any 24-hour window where shifts span more than 14 hours. Allow an "extraordinary emergency" override with a reason.
- **Break-length rules.** Paid breaks of 20 minutes or less stay on the clock. Unpaid deduction applies only to bona fide meals.
- **Rounding.** Federal rules allow neutral rounding to 5, 10, or 15 minutes (29 CFR 785.48). Neutral means it does not consistently favor the employer. Offer exact-minute as the default.

---

### Q4. Minimum wage, overtime, pay frequency, final pay, and tips

| Topic | Guam rule | Source | Confidence |
|---|---|---|---|
| Minimum wage | $9.25/hr since Sept 1, 2021. The statute shows no later increase. GDOL's Feb 2026 poster still lists $9.25. | 22 GCA § 3105; P.L. 36-001 | [Confirmed] |
| Federal minimum floor | If the federal minimum ever exceeds Guam's, Guam's rises to match on the same date. The federal rate is $7.25. | § 3121; 29 U.S.C. § 206 | [Confirmed] |
| Overtime | 1.5× regular rate over 40 hours per workweek. Comp time in place of overtime is not allowed for private employers (GDOL poster). | § 3107(a); 29 U.S.C. § 207 | [Confirmed] |
| Health-care 8/80 | Care institutions may use a 14-day period with overtime after 8 hours per day or 80 hours per period. | § 3215 | [Confirmed] |
| Exemptions | The statute sets $455/week for executive, administrative, and professional exemptions. The federal threshold is $684/week. The 2024 federal increase was vacated in Nov 2024. | § 3108(b); 29 CFR 541.600 | [Confirmed] for Guam text. [Secondary] for the vacatur. |
| Pay frequency | **No minimum frequency found.** Wages are due within 7 days after the end of each pay period. | § 3201 | [Confirmed] for the 7-day rule. [Not found] for frequency. |
| Discharge | "Immediately due and payable upon discharge." GDOL's FAQ says "Immediately, or by the next business day." | § 3201(a) | [Confirmed] |
| Voluntary quit | Next regular payday. | § 3201(b) | [Confirmed] |
| Disputed wages at termination | Pay the conceded amount unconditionally on time and notify the employee and the Director of Labor. Acceptance is not a release of the disputed amount. | § 3202 | [Confirmed] |
| Tip credit | **Not allowed.** "Wage" "shall not include tips or gratuities of any kind." GDOL: "'Tip credits' may not be used to meet the minimum wage." | § 3104; GDOL poster and F&B flyer | [Confirmed] |
| Tip ownership | The employer may not keep any part of employees' tips. Tip pools are allowed. Service charges are not tips: they are employer gross receipts, and any portion paid out counts in the regular rate for overtime. | GDOL poster; F&B flyer (<https://dol.guam.gov/wp-content/uploads/Flyer-for-Food-Beverage-Industry-2.16.2026.pdf>); 29 U.S.C. § 203(m)(2)(B) | [Confirmed] |
| Wage parity | An employer of non-immigrant aliens must pay U.S. citizens, permanent residents, and citizens of FSM, Palau, RMI, and CNMI at least as much as the aliens doing the same or substantially similar work. | § 3106 | [Confirmed] |
| Waivers | An employee cannot waive or compromise earned wages. | § 3220 | [Confirmed] |

**Penalties that make accuracy critical** **[Confirmed]**:

- Failure to keep § 3110 records is a misdemeanor (§ 3111).
- Unpaid minimum wage or overtime brings liquidated damages equal to the unpaid amount for willful violations (§ 3117(b)).
- Unpaid or underpaid wages bring punitive damages of **three times the wages due**, unless the employer proves eight affirmative-defense elements (§ 3219).
- A **12% collection fee** applies to wages collected by GDOL (§ 3218).
- Attorney's fees run at no less than $125/hour (§ 3221).
- Courts must "liberally permit" class actions (§ 3222).

**FLSA coverage note.**

- The FLSA applies in Guam. Its definition of "State" includes territories (29 U.S.C. § 203(c)). **[Primary, not re-read]**
- A very small Guam business with no FLSA enterprise or individual coverage is covered only by Guam law. The rules engine applies the stricter of the two, so the practical result is the same except for the exemption salary threshold.

**Tips and federal tax.**

- Tipped employees report tips to the employer monthly. FICA applies to reported tips.
- The 2026 Form W-2 adds code TP (cash tips), Box 14b (tipped occupation code), and code TT (the overtime premium) because of the 2025 federal "no tax on tips / overtime" deductions. **[Secondary]** (Journal of Accountancy, Aug 2025: <https://www.journalofaccountancy.com/news/2025/aug/draft-2026-form-w-2-includes-boxes-and-codes-for-tips-and-overtime/>)
- Whether W-2GU carries the same codes, and whether Guam's mirror code allows these deductions against Guam income tax, is a **DRT question** (Part 4B, item 8).

**What the product should do.**

- Hard-floor every hourly rate, and every salaried non-exempt employee's effective hourly rate, at $9.25.
- Never offer a tip-credit setting for Guam employers.
- Keep tips, tip-pool distributions, and service-charge distributions as separate earning types.
- Include service-charge distributions and non-discretionary bonuses in the regular rate.
- Run exemption checks against $684/week.
- On a termination entry of "discharged," the final pay date is today. On "resigned," it is the next regular payday. Add a § 3202 "conceded amount" notice template.

---

### Q5. Record retention

Where rules differ, keep the record for the **longest** applicable period. The product default should be the longest period in each row.

| Record type | Retention | Authority | Confidence |
|---|---|---|---|
| Payroll records: name, address, SSN or passport number, occupation, pay per period, daily and weekly hours | "Six (6) years" per GDOL handbook. The statute leaves the period to the Commissioner's regulations. | 22 GCA § 3110; GDOL FLSA Handbook p.7–8 | [Confirmed] (handbook statement). [Not found]: the regulation it relies on. |
| Copies of pay statements / check stubs | 3 years under the statute. Use 6 to match the handbook. | 22 GCA § 3212(a) | [Confirmed] |
| FLSA payroll records | 3 years | 29 CFR 516.5; DOL Fact Sheet 21 | [Confirmed] |
| FLSA time cards, wage-rate tables, schedules, records of additions and deductions | 2 years | 29 CFR 516.6; DOL Fact Sheet 21 | [Confirmed] |
| Employment tax records: W-4s, W-2 copies, deposits, returns, tip records | At least 4 years after the tax is due or paid, whichever is later | IRS Pub 15; IRS W-2/W-3 instructions ("at least 4 years") <https://www.irs.gov/instructions/iw2w3> | [Confirmed] (4-year rule) |
| Undeliverable employee W-2 copies | 4 years | IRS W-2/W-3 instructions | [Confirmed] |
| Form I-9 and any document copies | The later of 3 years after hire or 1 year after termination | 8 CFR 274a.2(b)(2)(i) <https://www.law.cornell.edu/cfr/text/8/274a.2> | [Confirmed] |
| E-Verify remote-exam document copies | Same as the I-9 | USCIS remote examination page <https://www.uscis.gov/i-9-central/remote-examination-of-documents> | [Confirmed] |
| Guam income tax withholding records | 4 years presumed, because Guam mirrors IRC § 6001 | Guam Territorial Income Tax (mirror code) | [Not found] (Guam-specific). DRT question. |
| FMLA records | 3 years | 29 CFR 825.500 | [Primary, not re-read] |
| Personnel records: hiring, promotion, discipline, termination | 1 year (Title VII/ADA); payroll 3 years under ADEA | 29 CFR 1602.14; 29 CFR 1627.3 | [Primary, not re-read] |
| Benefit plan records | 6 years | ERISA § 107 (29 U.S.C. § 1027) | [Primary, not re-read] |
| OSHA 300 injury logs | 5 years | 29 CFR 1904.33 | [Primary, not re-read] |
| Davis-Bacon certified payrolls and basic records | 3 years after all work on the prime contract is completed | 29 CFR 5.5(a)(3); 29 CFR 5.6 | [Secondary] (DOL supporting statement summarized in search) |
| H-2B (Guam) records | Not stated in what I read. Monthly reports go to GDOL (17 GAR § 7110). | Guam DOL H-2B Booklet 2026 | [Not found] |
| Guam new-hire reports | No retention period stated | 5 GCA ch. 34 | [Not found] |
| Biometric templates and geolocation punches | No Guam rule. Delete biometrics at separation. Keep punch locations as part of time records (2–6 years). | n/a | [Not found] |

Under Guam UETA, an electronic record satisfies a legal retention requirement if it "accurately reflects the information" and "remains accessible for later reference" (18 GCA § 91112(a)). A person may use "the services of another person" to retain it (§ 91112(c)). This supports a hosted archive. **[Confirmed]**

**What the product should do.**

- Apply a retention policy per record type. Default payroll and time data to **6 years** after the later of creation or separation. Use the I-9 formula for I-9s.
- Block deletion while a record is within its retention window.
- Support a legal hold.
- On client termination, export everything in a usable format.
- Keep the § 3110 data available "in or about the premises." Online access from the worksite should satisfy this, but confirm with GDOL.

---

### Q6. Electronic signatures and onboarding

**E-signature validity**

- **Guam UETA, 18 GCA ch. 91** (P.L. 33-015, effective Apr 1, 2015):
  - A signature "may not be denied legal effect… solely because it is in electronic form" (§ 91107(a)).
  - "If a law requires a signature, an electronic signature satisfies the law" (§ 91107(d)).
  - Attribution "may be shown in any manner, including a showing of the efficacy of any security procedure" (§ 91109(a)).
  - Exclusions: wills and testamentary trusts, and most of the UCC (§ 91103(b)).
  - **[Confirmed]** <https://col.guamcourts.gov/sites/default/files/18gc091.pdf>
- **Federal E-SIGN, 15 U.S.C. §§ 7001–7006**:
  - Covers transactions in or affecting interstate commerce.
  - States, including territories, that enact UETA may supersede it (§ 7002).
  - E-SIGN excludes certain notices from electronic delivery, including notices of cancellation or termination of health or life insurance benefits (§ 7003(b)(2)(C)).
  - **[Primary, not re-read]** <https://www.law.cornell.edu/uscode/text/15/chapter-96>

**Electronic Form W-4** (26 CFR 31.3402(f)(5)-1(c)) **[Confirmed]** <https://www.law.cornell.edu/cfr/text/26/31.3402(f)(5)-1>

- The system must "ensure that the information received by the employer is the information sent by the employee."
- It must document every access that results in a filing.
- Access controls must make it "reasonably certain that the person accessing the system and furnishing the Form W-4 is the employee identified in the form."
- Content and presentation:
  - The employee sees, and the employer receives, exactly the same information as the current IRS Form W-4.
  - The system must allow an exemption claim with both § 31.3402(n)-1(a) certifications.
  - The jurat uses the paper form's wording and immediately follows the withholding selections.
  - The electronic signature "must be the final entry."
- The employer must provide a hard copy plus a statement on IRS request.
- IRS substitute guidance: an electronic W-4 "must provide exactly the same information as the paper Form W-4." It must allow use of all parts of the calculation, must not limit Step 3 to dollar increments, and is "not a license to simplify or modify." **[Confirmed]** <https://www.irs.gov/forms-pubs/additional-guidance-for-substitute-submissions-of-form-w-4>
- **Guam:** Guam employers use the federal Form W-4 for Guam income tax withholding. **[Secondary]** I found no DRT publication saying so. One vendor mentions a "GU-4," which I could not verify. This is a DRT question.

**Electronic Form I-9** (8 CFR 274a.2) **[Confirmed]** <https://www.law.cornell.edu/cfr/text/8/274a.2>

- Section 2 must be completed within **3 business days** of the employee's first day. The employer "or its agent" examines the documents.
- Electronic storage (§ 274a.2(e)):
  - reasonable controls for integrity, accuracy, and reliability
  - controls against unauthorized alteration
  - an inspection and quality-assurance program
  - an index "functionally comparable to a reasonable hardcopy filing system"
  - "legible and readable hardcopies"
- Documentation of the system (§ 274a.2(f)).
- Security (§ 274a.2(g)): access limited to authorized personnel, backup and recovery, training, and a secure permanent record of each creation, completion, or change, showing who acted and what they did.
- Employee signature (§ 274a.2(h)):
  - acknowledge reading the attestation
  - "affix the electronic signature at the time of the transaction"
  - keep a record verifying the signer's identity
  - give a printed confirmation on request
- Employer attestation (§ 274a.2(i)).
- Copying documents is optional. Copying selectively by national origin or citizenship may violate 8 U.S.C. § 1324b (§ 274a.2(b)(3)).

**Section 2 for remote hires**

- **Standard path:** the employer may designate an *authorized representative*, such as a notary (acting without a seal), a household member, or an agent. That person physically examines the original documents with the employee present and completes Section 2. The employer stays liable for the representative's errors. **[Secondary]** (consistent law-firm and vendor guidance). USCIS's M-274 handbook is the primary source to cite: <https://www.uscis.gov/i-9-central/handbook-for-employers-m-274>
- **DHS alternative procedure** (live video), for **E-Verify employers in good standing at the hiring site**:
  1. Review copies of the documents, front and back.
  2. Hold a live video interaction where the employee presents the same documents.
  3. Check the "alternative procedure" box in Section 2 (editions 08/01/2023 and 01/20/2025).
  4. Keep clear copies.
  - Consistency rule: if offered at a site, apply it consistently. It may be limited to remote hires, but not for a discriminatory purpose.
  - The employer must complete E-Verify's fraudulent-document training.
  - **[Confirmed]** USCIS page (last updated 09/26/2025): <https://www.uscis.gov/i-9-central/remote-examination-of-documents>
- **Guam-specific documents:** Form I-9 List A includes an FSM or RMI passport with Form I-94 showing admission under the Compact of Free Association. This matters for Guam's workforce. **[Primary, not re-read]** <https://www.uscis.gov/i-9-central/form-i-9-acceptable-documents>

**Guam new-hire reporting** (5 GCA §§ 34301–34306) **[Confirmed]**

- "Employers shall submit reports… within twenty (20) calendar days of the date of hiring or rehiring" (§ 34303).
- Reports go to the Director of New Hires: the Attorney General or a designee, through the Child Support Enforcement Division.
- Content (§ 34306): the employee's name, address, SSN, and date of birth when available, plus the employer's name, address, and federal EIN.
- Format (§ 34305(a)): a copy of the W-4, a W-9, or any document with that data, delivered by mail, fax, or electronic means.
- **Electronic reporters must submit twice a month, 12–16 days apart** (§ 34305(b)).
- Penalties (§ 34304): written notice first, then $24 per intentionally unreported employee, or $499 where employer and employee conspire.
- **[Not found]**: a current CSED portal or electronic file specification. Ask the CSED.

**Other onboarding items**

- Policy acknowledgments have no Guam-specific rule. Use UETA-compliant e-signatures with versioned documents.
- Guam's Right to Privacy in the Workplace Act bars asking employees or applicants for social-media or personal-email credentials, with fines of $1,000 for a first offense and $2,000 after (22 GCA § 3501). **[Confirmed]**
- Minors aged 14–15 need a Minor's Certificate for Employment (19 GCA ch. 11, per GDOL poster). **[Confirmed]** (poster)

**What the product should do.**

- Build W-4 and I-9 flows that meet the rules above:
  - strong authentication: login plus a one-time code
  - signature as the last step, with timestamp, IP or device, and a document hash
  - an immutable audit log of create, complete, and change events
  - PDF rendering identical to the official form edition
- Track I-9 edition changes, the Section 2 deadline, reverification dates, and an authorized-representative flow. The representative gets a limited-scope login and attests to physical examination.
- Support the E-Verify alternative procedure only for employers that record E-Verify enrollment. Add a per-site "consistent use" setting.
- Never let the employer choose which documents an employee presents. Show the full List A/B/C, including the Compact passport.
- Generate the Guam new-hire report automatically from onboarding data. Batch it twice monthly if filing electronically, and alert at day 15 for any unreported hire.

---

### Q7. Electronic W-2/W-2GU delivery and year-end filing

**IRS electronic-furnishing rule** (26 CFR 31.6051-1(j)) **[Confirmed]** <https://www.law.cornell.edu/cfr/text/26/31.6051-1>

- **Consent:** affirmative consent "in a manner that demonstrates that the recipient can access" the form in the format used. Paper consent is acceptable only if confirmed electronically. A new consent is needed after hardware or software changes that create a material risk the employee cannot open the form.
- **Disclosures, before or at consent:**
  - paper will be furnished if the employee does not consent
  - scope and duration of the consent
  - how to get a paper copy
  - how to withdraw, and that withdrawal does not affect forms already furnished
  - when electronic furnishing ends, such as at separation
  - how to update contact information
  - hardware and software requirements
  - the date the form will no longer be posted
- **Notice:** if the form is posted to a website, tell the employee. The notice must contain "IMPORTANT TAX RETURN DOCUMENT AVAILABLE," in the email subject line when sent by email. If the email bounces, send notice by mail or in person within 30 days.
- **Availability:** keep the form posted through **Oct 15** of the following year. Corrected forms stay posted through the later of Oct 15 or 90 days after posting.
- **Withdrawal:** if consent is withdrawn before furnishing, send paper within 30 days.

**Does Guam DRT follow it for W-2GU?**

- I found no DRT statement either way. **[Not found]**
- Guam's income tax is the IRC "mirrored" for Guam, which suggests the Treasury regulation applies by mirror. That is an inference, not an authority. **DRT confirmation needed.**
- The IRS W-2 instructions, which cover W-2GU, say electronic furnishing of Copies B, C, and 2 is permitted. **[Confirmed]** <https://www.irs.gov/instructions/iw2w3>

**Filing W-2GU**

- **SSA:** File Copy A of W-2GU with W-3SS. Use BSO online forms, or BSO file upload in **EFW2** format above 50 forms. **Do not truncate SSNs on Copy A of W-2GU.** E-filing is required when combined information returns total 10 or more. **[Confirmed]** (IRS instructions)
- **Guam DRT** **[Confirmed]** <https://www.guamtax.com/help/help_w2w3.html>:
  - File Copy 1 electronically through **GuamTax.com**, as ASCII in SSA's EFW2 layout. An e-filing there "constitutes official filing."
  - **Payroll processors** must have their GuamTax account "marked as a payroll processor account." Registration is by form, faxed or mailed. Processors may upload many companies in one file.
  - "If you have companies with different EINs, you must establish a separate GuamTax account for each EIN." (The FAQ describes this for registrants. Ask how it interacts with the processor flag.)
  - **Corrected W-2GUs cannot be e-filed** on GuamTax ("only… original W-3/W-2GU reports").
  - Zero-employee reports must be filed on paper.
- **Deadline:** Jan 31, for paper and e-file, with **no automatic 30-day extension** (DRT Tax Alert 23-01). For tax year 2026, the IRS instructions give **Feb 1, 2027** for SSA filing and employee furnishing, because Jan 31 is a Sunday. **[Confirmed]** for SSA and employees. The Tax Alert covers 2023 forms and doesn't state DRT's 2026 date or weekend rule. **[Not found]**: ask DRT, and file with DRT by Jan 29, 2027 until it answers. <https://www.guamtax.com/notices/TaxAlert23-01-ITAPB-EmployerNotificationW3SSW2GUAND10961099-2023UPDATED12202023.pdf>
- **E-file threshold:** 10 or more information returns, counting W-2GUs and 1099s together, under the Guam Territorial Income Tax Code § 6011(e)(2)(A) and T.D. 9972. **[Confirmed]** The alert also says the requirement "applies separately for each type of form," which conflicts with the aggregation language. Ask DRT.
- **Full SSNs and EINs:** DRT requires them on W-3SS/W-2GU and 1096/1099 forms. **[Confirmed]** Employee-copy truncation is allowed federally. Whether DRT accepts truncated employee copies: **[Not found]**.

**1099s for Guam payers**

- File with DRT through GuamTax.com, ASCII per IRS Pub 1220.
- Payroll-processor accounts may upload for other companies.
- 1099-NEC is due Jan 31, with no automatic extension, per Tax Alert 23-01.
- Other 1099 due dates are not stated on the DRT pages I read. **[Not found]** for current-year dates of 1099-MISC and similar forms.
- **[Confirmed]** <https://guamtax.com/help/help_1099.html>

**Related federal change**

- Form 941-SS was discontinued after 2023. Guam employers now file Form 941 for FICA. **[Secondary]**; the IRS page notes "discontinued after 2023": <https://www.irs.gov/form941ss>
- Guam income tax withholding is remitted to DRT, not the IRS. **[Not found]**: current DRT form name and deposit schedule. Confirm with DRT.

**What the product should do.**

- Build an EFW2 generator that produces separate SSA (Copy A) and DRT (Copy 1) submissions.
- Track GuamTax account and EIN mapping per client.
- Provide a paper W-2c / W-3cSS workflow.
- Enforce a year-end calendar that warns 30 days before Jan 31 and adjusts for weekends.
- Run the electronic-W-2GU consent flow above, separate from the pay-stub consent, because the IRS consent has its own disclosure set. Print paper W-2GUs for non-consenters.
- Keep W-2GUs online through Oct 15, then archive them. Keep corrected W-2GUs online through the later of Oct 15 or 90 days after posting.

---

### Q8. Data security and privacy

**FTC Safeguards Rule (16 CFR Part 314, under GLBA)** **[Confirmed]** <https://www.ftc.gov/business-guidance/resources/ftc-safeguards-rule-what-your-business-needs-know>

- **Who it covers:** "financial institutions" under FTC jurisdiction. The definition turns on activities, not labels, and the FTC lists **tax preparation firms** as an example. The IRS says tax and accounting professionals are covered and need a WISP (below).
- **Cornerstone:** its tax-preparation activity is clearly covered.
- **Shimizu:** whether a payroll software vendor or payroll processor is itself a "financial institution" for employee data is **unresolved**. **Law firm question.** Shimizu is at minimum a **service provider** that Cornerstone must oversee by contract (§ 314.4(f)).
- **Required program (§ 314.4):**
  - (a) a Qualified Individual
  - (b) a written risk assessment
  - (c) safeguards:
    - periodically reviewed access controls
    - inventory of data and systems
    - **encryption at rest and in transit**, or alternative controls approved by the Qualified Individual
    - secure-development and app-security procedures
    - **MFA** for anyone accessing customer information
    - disposal within **2 years** of last use unless needed
    - change management
    - user-activity logging and monitoring
  - (d) continuous monitoring, or **annual penetration testing plus vulnerability scans every 6 months**
  - (e) security training
  - (f) service-provider oversight in contracts
  - (g) keep the program current
  - (h) a written incident response plan
  - (i) an annual written report to the board or a senior officer
- **FTC breach notice (§ 314.4(j)):** report a "notification event" to the FTC as soon as possible, **no later than 30 days** after discovery. A notification event is unauthorized acquisition of unencrypted customer information of **500 or more consumers**. Unauthorized access is presumed to be acquisition. Use the FTC online form.
- **Small-entity relief:** institutions with customer information on fewer than 5,000 consumers are exempt from some elements (§ 314.6). **[Primary, not re-read]**: the exempt elements are the written risk assessment, penetration testing, the written incident response plan, and the annual report.

**IRS Pub 4557 / Pub 5708 (WISP)**

- The IRS says federal law requires tax professionals to have a written information security plan.
- Pub 5708 is the IRS template. Pub 4557 is the companion safeguards guide.
- **[Secondary]** for the wording; the IRS news release is primary: <https://www.irs.gov/newsroom/irs-security-summit-remind-tax-pros-they-need-a-written-information-security-plan-to-protect-client-data>
- Cornerstone needs a WISP that names this platform as a covered system.

**IRC § 7216 (tax return information)**

- Tax return preparers face criminal and civil penalties for unauthorized use or disclosure of return information. Disclosure to service providers that assist preparation is allowed under Treas. Reg. § 301.7216-2.
- Whether payroll and W-2GU data processed by Cornerstone counts as "tax return information" under § 7216 (or Guam's mirror), and whether any employee-app feature could be "use" needing consent, is a **law firm question**.
- **[Primary, not re-read]** <https://www.law.cornell.edu/cfr/text/26/301.7216-2>

**Guam breach notification law (9 GCA §§ 48.10–48.80, P.L. 30-004, Mar 13, 2009)** **[Confirmed]** <https://statecodesfiles.justia.com/guam/2024/title-9/chapter-48/chapter-48.pdf>

- **"Personal information":** first name or initial and last name, linked to an unencrypted and unredacted:
  - SSN
  - driver's license or Guam ID number
  - financial account or card number together with any required code or password
- **Breach:** "unauthorized access and acquisition" of unencrypted, unredacted computerized data that compromises personal information, and that causes or is reasonably believed to cause identity theft or fraud.
- **"Redact":** no more than 5 digits of an SSN, or the last 4 digits of a license or account number, are accessible.
- **Owner or licensee:** must notify affected Guam residents "without unreasonable delay" (§ 48.30(a)). Law-enforcement delay is allowed (§ 48.30(d)). Encrypted data counts if the key was also compromised (§ 48.30(b)).
- **An entity that maintains data it does not own** must notify the owner "as soon as practicable following discovery" (§ 48.30(c)). **This is Shimizu's duty to Cornerstone and to client employers.**
- **Notice methods:** written, telephone, or electronic notice. Substitute notice is allowed when cost exceeds $10,000, more than 5,000 people are affected, or contact information is lacking.
- **Safe harbors:** your own procedures consistent with the timing rules (§ 48.40(a)), or compliance with your federal functional regulator's rules (§ 48.40(b)).
- **Enforcement:** the Attorney General only. Actual damages, or a civil penalty up to **$150,000 per breach** or series of similar breaches (§ 48.50).
- **No regulator notice** is required by the Guam law.

**Guam privacy law:** no comprehensive Guam consumer privacy statute found. **[Not found]** (consistent with secondary trackers). The workplace credential-request ban (22 GCA § 3501) is the only Guam employee-privacy statute I found.

**What the privacy notice and client data terms should cover**

*Employee-facing privacy notice:*
- what data is collected: identity, SSN, bank, pay, time, location at punch, device, biometric templates if used
- why it is collected: payroll, tax, legal compliance
- who sees it: the employer, Cornerstone, Shimizu, named sub-processors, government agencies
- retention periods
- security measures
- how to view and correct data, and request direct-deposit changes
- SMS terms
- breach notification commitment
- contact
- The notice must be accurate. A misleading privacy statement is an FTC Act § 5 risk.

*Client data processing addendum:*
- roles: the employer owns the data; Cornerstone and Shimizu process it under instructions
- permitted uses, with no sale and no AI training without written consent
- sub-processor list and change notice
- data location
- security schedule mapped to 16 CFR 314.4
- breach notice to the client within a fixed time (for example 72 hours), plus cooperation; Guam's "as soon as practicable" is the legal floor
- assistance with employee notices and FTC filings
- audit rights or a SOC 2 report
- confidentiality
- retention, return, and deletion at termination, with legal-retention carve-outs
- insurance, indemnity, and liability caps

**What the product should do.**

- **Required:**
  - MFA for all admin and Cornerstone users
  - MFA or one-time-code login for employees viewing SSN or bank data
  - field-level encryption for SSNs and bank account numbers; show only the last 4 by default
  - TLS everywhere
  - per-tenant isolation
  - role-based access with least privilege
  - immutable audit logs for views and exports of SSN and bank data
  - quarterly access reviews
  - documented change management
  - an incident runbook that meets the FTC 30-day and Guam deadlines
- **Direct-deposit change requests are a top fraud target.** Require re-authentication, notify the old email and phone, hold the change for one pay cycle or require employer approval, and never accept bank changes by email.
- **Data minimization:** do not store full bank numbers in logs, exports, or emails.

---

### Q9. Text messaging (TCPA)

**Consent rules.**

- Under 47 CFR 64.1200(a), texts count as "calls."
- Autodialed or prerecorded calls and texts to wireless numbers need **prior express consent**. Telemarketing needs **prior express written consent**.
- The FCC has long held that a person who gives their number has generally consented to related informational contact at that number.
- *Facebook v. Duguid* (2021) narrowed "autodialer." That does not make consent unnecessary, and many platforms may still be risky.
- **[Primary, not re-read]** <https://www.ecfr.gov/current/title-47/chapter-I/subchapter-B/part-64/subpart-L/section-64.1200>

**Transactional vs marketing.** Pay-ready, schedule-change, shift-reminder, and document-to-sign texts are informational. Anything promoting a product or service, including a client's own business offers, is telemarketing and needs written consent. The platform should not send marketing at all.

**Revocation.**

- The 2024 FCC rules require honoring revocation by any reasonable means **within 10 business days**. They took effect April 11, 2025.
- The FCC's newer order **FCC 26-67** (published Oct 26, 2026; **effective Nov 25, 2026**):
  - allows informational opt-outs to apply only to that message category
  - keeps "revoke-all" for telemarketing
  - lets senders designate exclusive opt-out methods, such as standard keyword replies
  - requires honoring STOP, QUIT, END, REVOKE, OPT OUT, CANCEL, and UNSUBSCRIBE
- **[Secondary]** (CommLaw Group, Burr & Forman summaries: <https://commlawgroup.com/2026/fccs-new-tcpa-consent-revocation-rules-on-category-specific-opt-outs/>). Read the Federal Register text (2026-21821) before building.

**A2P 10DLC.**

- U.S. carriers require business texts sent from 10-digit long codes to be registered through The Campaign Registry as a brand plus a campaign.
- Unregistered traffic has been blocked since early February 2025. **[Secondary]** (carrier and vendor sources such as Telnyx)
- Design decision: register **each client employer as its own brand** under an ISV/reseller setup, or send under one Shimizu or Cornerstone brand. The campaign use case is likely "account notifications" or "customer care."
- **Guam carriers' 10DLC enforcement: [Not found].** Test with the SMS provider, since most employees will be on local Guam carriers.

**Employment-law angle.** Texting non-exempt employees off-shift can create compensable work time if they must read or respond. Keep texts informational and avoid requiring replies off the clock.

**What the product should do.**

- Opt-in at onboarding that is separate from other consents. Store the disclosure text: program name, message types, frequency, "Msg & data rates may apply," and HELP/STOP instructions. Record timestamp, phone, and source.
- Per-category toggles.
- Process STOP and the other keywords immediately and send one confirmation.
- Quiet hours.
- Email fallback for employees without SMS consent.
- Never make SMS consent a condition of employment. Critical pay information must stay available in-app or by email.

---

### Q10. Geolocation and biometric time clocks

**Geolocation.**

- **Guam:** no statute found on employer location tracking. **[Not found]**
- **Federal:** no general federal statute bars an employer from collecting location at punch with notice. **[Not found]**: a specific federal prohibition.
- **NLRA:** surveillance that chills protected concerted activity can be an unfair labor practice. The 2022 NLRB General Counsel memo on electronic monitoring (GC 23-02) was rescinded in Feb 2025 (GC 25-05). The NLRA itself still applies. **[Secondary]**
- **Personal phones:** requiring employees to buy phones or data plans for work could cut into the minimum wage. Wages must be paid "free and clear" (29 CFR 531.35). **[Primary, not re-read]**

**Biometrics.**

- **Guam:** no biometric privacy law found. Secondary trackers list none for Guam. **[Not found]**
- **FTC:** the May 2023 policy statement on biometric information warns that unfair or deceptive biometric practices violate FTC Act § 5. Examples include no notice, poor security, and no assessment of foreseeable harms. **[Primary, not re-read]** <https://www.ftc.gov/legal-library/browse/policy-statement-federal-trade-commission-biometric-information-section-5-federal-trade-commission-act>
- Title VII religious-accommodation claims have arisen over hand and finger scanners. **[Secondary]**
- Illinois BIPA and Texas and Washington laws do not apply in Guam but set the expected standard.

**Recommended notice and consent.**

- Written notice before enrollment covering:
  - what is collected (location at punch only; a biometric template, not the image)
  - why it is collected (time accuracy, buddy-punch prevention)
  - who receives it
  - retention, including deletion within a fixed period after separation
  - security
- A signed acknowledgment.
- A **non-biometric alternative** for anyone who objects (PIN, badge, supervisor punch).
- No continuous or background tracking, and no location capture off the clock.
- Geofence results ("inside / outside approved area") stored in place of, or alongside, raw coordinates. Coordinates kept with access limits.
- Biometric templates encrypted and never sold or shared.
- Kiosks: on-device matching where possible.

---

### Q11. H-2B workers and federal contract construction

**H-2B in Guam is run by Guam, not U.S. DOL.**

- 20 CFR 655.3: the federal H-2B labor-certification subpart "does not apply to temporary employment in the Territory of Guam." U.S. DOL "does not certify to DHS the temporary employment of H-2B nonimmigrant foreign workers, or enforce compliance with the provisions of the H-2B visa program, in the Territory of Guam." **[Confirmed]** <https://www.law.cornell.edu/cfr/text/20/655.3>
- The Governor of Guam issues the temporary labor certification. Guam DOL's Alien Labor Processing & Certification Division (ALPCD) administers it. **[Confirmed]** (Guam DOL H-2B Program Booklet 2026, rev. 8/22/26: <https://dol.guam.gov/wp-content/uploads/H-2B-Program-Booklet-2026-rev-8-22-26.pdf>)
- So the federal H-2B pay rules (20 CFR 655.20: three-quarter guarantee, earnings statements) are **not** the Guam rule set. Guam's own rules apply: 17 GAR Chapter 7, as reproduced in the booklet, plus 22 GCA ch. 3.

**Guam H-2B pay and record obligations** **[Confirmed]** (booklet, 17 GAR ch. 7):

- **Prevailing wage:** pay at least the prevailing wage on the certification. The Guam construction prevailing wages took effect 8/24/26 (for example, carpenters $19.10 and electricians $21.36). U.S. and foreign workers must get no less.
- **Wage parity:** local workers doing the same or substantially similar work get at least the alien workers' wages (22 GCA § 3106). It is a second-degree felony to knowingly favor non-immigrant workers over local workers in employment or pay (22 GCA § 3223).
- **Board and lodging:** employers certified for more than five workers must provide lodging and meals (17 GAR § 7108). Charges are capped at actual cost.
  - Over $80/week needs GDOL approval and records.
  - **Deductions need the worker's written authorization, filed with GDOL** (§ 7108(c)).
  - The booklet's standard allowable deduction is **$80/week**.
- **Monthly report by the 7th** (17 GAR § 7110), covering each worker's name, address, citizenship, visa category, SSN, residence, occupation, certification dates, project, actual costs of benefits, and **a true accounting of deductions from pay**.
- **Other:** exit clearance at least 15 days before departure (§ 7107); no withholding of passports except with written authorization filed with GDOL (§ 7109); wage and repatriation bonds.
- **No off-island transmittal deductions:** "No employer of non-immigrant alien employees may deduct from their pay any funds for transmittal off-island" (22 GCA § 3212(b)).

**Davis-Bacon and certified payroll.**

- Contractors on covered federal or federally assisted construction must:
  - pay the wage-determination rates and fringes by classification
  - submit **weekly certified payrolls** with a signed Statement of Compliance; Form WH-347 is optional, but the wording must match
  - keep payroll and basic records **3 years after all work on the prime contract is completed**
  - follow Copeland Act anti-kickback limits on deductions (29 CFR part 3)
- **[Secondary]** for details (DOL supporting statement, law-firm summaries). Primary: 29 CFR 5.5(a)(3) <https://www.ecfr.gov/current/title-29/subtitle-A/part-5>
- U.S. DOL conducts Davis-Bacon wage surveys in Guam, so Guam wage determinations exist. **[Confirmed]** (DOL news release: <https://www.dol.gov/newsroom/releases/whd/whd20240403>)
- Whether a given Guam project is covered depends on the funding statute. **[Secondary]**
- The 2023 DOL final rule also requires keeping each worker's last known phone number and email. **[Secondary]**; verify against 29 CFR 5.5(a)(3)(i).
- Clients with federal service contracts on Guam (for example, base services or aviation training) may fall under the **Service Contract Act** instead. **[Not researched in depth]**

**What the product should do.**

- Add an employee "visa class" field.
- **H-2B board-and-lodging deduction type:** blocked unless a GDOL-filed written authorization is attached. Capped at the **lower of actual cost or $80/week**, unless a GDOL approval notice is on file. Store the actual weekly cost and check the deduction against it.
- Monthly **GDOL Workplace Report** export.
- **Wage-parity check:** compare each local worker's rate with the rates of H-2B workers in the same occupation.
- Never allow a "remittance" deduction for H-2B workers.
- **Certified-payroll module:** project, classification and rate tables with fringes, a WH-347-equivalent weekly report with the Statement of Compliance and e-signature, a 3-year post-project retention lock, and capture of worker phone and email.

---

### Q12. Contracts and responsibility split

**Tax liability stays with the employer.**

- IRS: "The employer is ultimately responsible for the deposit and payment of federal tax liabilities… If the third-party fails to make the federal tax payments, then the IRS may assess penalties and interest on the employer's account." **[Confirmed]** <https://www.irs.gov/businesses/small-businesses-self-employed/outsourcing-payroll-duties>
- **Reporting agent:** authorized on Form 8655. Must deposit through EFTPS. Is "not liable as either an employer or an agent of the employer" for the taxes.
- Rev. Proc. 2012-32 requires a **quarterly written statement** to clients that they remain responsible for filing and payment.
- Clients should use the EFTPS Inquiry PIN to verify deposits.
- A section 3504 agent (Form 2678) shares liability. A CPEO is solely liable.
- **[Secondary]** (IRS page content returned in search; IRS Pub 15 is primary)

**CPA confidentiality.** Before sharing confidential client information with a third-party service provider, an AICPA member needs either a confidentiality agreement with the provider or the client's specific consent (ET § 1.700.040). Cornerstone's contract with Shimizu should therefore include confidentiality and security terms. **[Secondary]** (Journal of Accountancy and others: <https://www.journalofaccountancy.com/issues/2015/mar/aicpa-confidentiality-rule.html>). Guam Board of Accountancy rules: **[Not found]**.

**Client service agreement (payroll service + software) should cover:**

1. **Parties and roles.** The employer is the employer of record and the data owner. Cornerstone is the payroll service provider and, where authorized, reporting agent. Shimizu is the software provider and sub-processor. State which entity contracts with the client.
2. **Services.** Scope: payroll calculation, tax deposits and filings (which ones, at which agencies: IRS, SSA, DRT, CSED), W-2GU/1099, time and attendance, employee app, H-2B and certified-payroll modules. List excluded services.
3. **Employer responsibilities:**
   - accuracy and timely approval of hours, rates, and changes
   - worker classification (exempt/non-exempt, employee/contractor)
   - meal-break and split-shift compliance, and policies
   - I-9 Section 2, unless Cornerstone is the authorized representative
   - postings
   - final-pay decisions
   - **funding by a set time before payday**
   - prompt review of payroll previews and notices
   - keeping EFTPS and GuamTax access
4. **Provider responsibilities:**
   - compute from the data supplied
   - deposit and file on time if funded
   - forward agency notices within a set number of days
   - fix provider-caused errors at no charge
   - security program and breach notice
5. **Penalties.** The provider pays penalties and interest caused solely by its own error or late action. The employer pays those caused by late funding, bad data, or late approval. The underlying tax is always the employer's. Name a notice-forwarding deadline as a condition.
6. **Funds handling.** Pre-funding or debit timing, NSF handling, and holding funds in trust. *Moving client funds can trigger Nacha Third-Party Sender obligations and possibly money-transmitter licensing. Law firm question, not researched here.*
7. **Required IRS disclosures:** the quarterly statement if Cornerstone is a reporting agent, and a Form 8655 on file.
8. **Data and security:** the DPA described in Q8, plus § 7216 consent language if counsel says it is needed.
9. **Electronic records and communications:** the client agrees to e-records and e-signatures, and directs the platform to collect employee consents.
10. **Term and exit:** data export, transition help, and the retention period after termination.
11. **Warranties, disclaimers, limitation of liability** (often capped at fees, with carve-outs for data breach and gross negligence), indemnities each way, insurance (E&O and cyber), governing law (Guam), and disputes.
12. **"Not legal advice."** Configuration help such as holiday policies or exemption flags is not legal advice. The employer decides policy.

**Employee app terms of service:** who the service is for; account security; employer control of the account and data; that the terms create no employment contract; acceptable use; electronic-delivery and SMS consents, each separate; how to correct data; availability and support; privacy notice link; changes to terms.

---

## Part 3. Questions for the law firm

Updated 2026-11-19 after reviewing how Cornerstone works today (Part 5). Questions are grouped by when they matter.

**Needed before launch**

1. **Direct deposit.** Does 22 GCA § 3212(b) ("cash or check") allow direct deposit with employee consent? Can an employer require direct deposit, or pay by payroll card? MoSa's December 2024 memo says the business is "moving to paying all employees by direct deposit." Should that memo and the authorization form say direct deposit is optional and a check is available?
2. **Electronic pay stubs.** Under Guam UETA, is an employee's in-app click-through enough agreement to receive § 3212 pay statements electronically? Must a paper option stay available indefinitely?
3. **Meal waivers.** Does the § 3107(c) meal waiver need a written document? Is a standing waiver valid, or must consent be given per shift? Which trigger applies: "more than 5 hours" (statute) or "5 hours or more" (GDOL poster)?
4. **Retention.** Which regulation sets GDOL's "six (6) years," and how does it square with the 3 years in § 3212 for pay-stub copies?
5. **Safeguards Rule.** Is Shimizu Technology a "financial institution" under the FTC Safeguards Rule because of payroll processing, or only Cornerstone's service provider? Same question for Cornerstone's payroll work, as distinct from its tax preparation.
6. **IRC § 7216.** Does § 7216 (or Guam's mirror) apply to payroll and W-2GU data that Cornerstone processes? Do any employee-app features need § 7216 consents?
7. **Breach notice.** Who is the "owner or licensee" of employee data under 9 GCA § 48.30: the employer, Cornerstone, or both? Who sends breach notices?
8. **Client agreement.** What penalty allocation and liability caps are typical for Guam payroll service agreements? Cornerstone today makes EFTPS deposits and prepares returns that clients sign, with no Form 8655 on file (Part 5). Does the Guam Board of Accountancy have rules on Cornerstone offering software?
9. **Text messages.** Under FCC 26-67 (effective Nov 25, 2026), are employer-to-employee pay and shift texts "informational"? After *Facebook v. Duguid*, does the platform's sending method count as an autodialer? Who is the "caller": the employer, Cornerstone, or Shimizu?
10. **Biometrics.** Is there any Guam privacy or religious-accommodation exposure from biometric clocks? Should the product offer them at launch?
11. **Geolocation.** Is there any Guam rule or collective-bargaining issue with requiring location at clock-in? Can an employer require employees to clock in on their own phones?
12. **FUTA.** A DOL study says Guam would need congressional action to be treated as a FUTA "state." Confirm that Guam employers typically owe no FUTA and file no Form 940, and list any exceptions.

**Later or lower priority**

13. **Handling client payroll money.** Lower priority while each employer sends its own ACH from its own bank (Part 5). Revisit before Cornerstone or Shimizu ever pre-funds, holds or moves client money: Nacha Third-Party Sender rules, Guam money-transmitter licensing, FinCEN money services business rules.
14. **Cornerstone as I-9 representative.** Can Cornerstone act as an I-9 authorized representative for clients, and what liability would it take on? This matters only if Cornerstone will complete Section 2 for clients.
15. **H-2B.** Should the platform generate GDOL monthly reports, and who is liable if a report is wrong because of platform data? No current clients have H-2B workers.
16. **Benefit notices.** E-SIGN (§ 7003) excludes notices that health or life benefits are ending. Does Guam UETA carry a similar exclusion, and must those notices go on paper? This matters only if benefit notices go through the app.

---

## Part 4. Questions for Cornerstone, Guam DRT, Guam DOL and the CSED

### 4A. Cornerstone

Most earlier questions were answered (Part 5). Two remain.

1. Was the written information security plan (WISP) finished after the March 2026 training? If it was, the platform needs to be added to it as a covered system.
2. For filing, should Cornerstone keep working as it does now, with clients signing their own 941s and Cornerstone using each client's own GuamTax login? Or should it register on GuamTax as a payroll processor, and possibly become an IRS reporting agent (Form 8655)?

### 4B. Guam DRT

Cornerstone's owner led DRT until recently, so these go through her. Written answers are best, so the law firm can rely on them.

1. Does DRT accept W-2GUs given to employees electronically with consent, under the IRS rules in 26 CFR 31.6051-1(j)?
2. Can employee copies show only the last 4 digits of the SSN? DRT copies need the full number.
3. How does a payroll-processor account work alongside "one GuamTax account per EIN"? Can corrected W-2GUs (W-2c/W-3cSS) be e-filed yet?
4. Is the 10-return e-file threshold counted across W-2GUs and 1099s combined, or for each form type? Tax Alert 23-01 says both.
5. What are the current due dates for 1099-MISC and other non-NEC 1099s filed with DRT?
6. What is the Guam income tax withholding return (form name) and its deposit schedule?
7. Is the federal Form W-4 the Guam withholding certificate, or does a Guam version (such as a "GU-4") exist?
8. Will the 2026 W-2GU include codes TP and TT and Box 14b? Do the federal deductions for tips and overtime apply against Guam income tax?

### 4C. Attorney General's Child Support Enforcement Division

1. Is there an electronic file format or portal for new-hire reports, given the 20-day deadline and the twice-monthly rule for electronic filers (5 GCA §§ 34303, 34305)?

### 4D. Guam DOL Wage & Hour Division (wage.questions@dol.guam.gov)

1. Is direct deposit allowed under § 3212(b)? Are payroll cards?
2. Are electronic pay statements acceptable, and what employee consent does GDOL expect?
3. Which regulation sets the 6-year record retention? Does online access satisfy keeping records "in or about the premises"?
4. Is there a preferred format for meal-period waivers?
5. Is there a minimum pay frequency (weekly, biweekly, semimonthly, monthly)?
6. Is any increase to the minimum wage above $9.25 pending or scheduled?
7. Is there a form or format for the § 3213 statement employers must give when wages are not paid on time?
8. ALPCD (later, for H-2B): can the monthly report under 17 GAR § 7110 be filed electronically, and how do deduction authorizations get filed?

---

## Part 5. How Cornerstone works today (added 2026-11-19)

Sources: Leon's answers, and a read-only review of the Cornerstone mailbox. No employee names, account numbers or credentials are copied here.

| Topic | What we found | What it means |
|---|---|---|
| Direct deposit (MoSa's) | Cornerstone drafted a direct-deposit authorization form and an employee memo in Dec 2024. The form authorizes the employer to credit the employee's account, requires a voided check or bank certification, and stays in effect until written termination. The memo says the employer is "moving to paying all employees by direct deposit." In practice, about a dozen employees still received paper checks as of Sept 2026. Direct-deposit employees get a payment advice instead of a check. | Practice is mixed, which fits § 3212(b) better than the memo's wording. Questions 1 and 2 still go to Guam DOL. The form should say direct deposit is optional and a check is available. The product needs per-employee check-or-deposit settings and payment advices for deposit employees. |
| How ACH is set up | The employer has its own ACH origination agreement with its bank (set up Jan 2025, with processing limits and token-based login). | The employer is the ACH originator, so Cornerstone is not holding client payroll money. That makes the Nacha and money-transmitter concerns in Q12 smaller, as long as that model stays. |
| Tax filing | Cornerstone prepares the returns and makes the EFTPS deposits. The client still signs the Form 941, and one example was mailed on paper to the IRS (Q3 2025). I found no Form 8655. | Cornerstone acts as a payroll service provider, not an IRS reporting agent, and the employer stays the filer. The client agreement should say so (Q12). Becoming a reporting agent later would add the Rev. Proc. 2012-32 quarterly-notice duty. |
| GuamTax.com | Each client has its own GuamTax account, and Cornerstone signs in for them (per Leon). | Using clients' logins works, but DRT offers a payroll-processor account for this. Ask DRT whether Cornerstone should register as a processor (Part 4B, item 3; also Part 4A, item 2). |
| Logins and passwords | Some client EFTPS and other logins appear to be exchanged by email (based on subject lines; I did not open them). | This is a Safeguards Rule and WISP risk. The platform should never ask for or store client bank or EFTPS passwords. Cornerstone should keep them in a password manager with MFA. |
| Security plan | In March 2026 Cornerstone scheduled mandatory staff training on IRS Pubs 4557, 5708 (WISP template), 5709 and 5417. I found no finished WISP. | Ask whether the WISP was finished. If so, add this platform as a covered system. |
| Engagement letters | The Cornerstone letters I found are short. A Nov 2025 tax engagement lists scope, fees and short responsibility bullets: confidentiality, timely information, notice of delays, 30-day termination. MoSa's has a July 2024 quote listing payroll, tax payments, quarterly returns, W-2s, GRT and 1099s. I found no payroll-specific agreement covering penalties, funding deadlines or accuracy of hours. | Write a new payroll service agreement and data processing addendum using the Q12 checklist. |
| 401(k) deposits | In 2024–2026 there was correspondence about late 401(k) contributions and a plan compliance notice. | Withheld amounts owed to others are "unpaid wages" if not remitted within 5 days after the day the employee's pay is due (22 GCA § 3217(b)). Federal plan-deposit rules also apply. The product should track and alert on remittance due dates for every third-party deduction. |
| Client differences | Meal waivers, holiday pay, I-9 handling and new-hire reporting differ by client (per Leon). | Make all of these per-employer settings, as Part 1 assumes. |
| W-2GU delivery | Cornerstone used outside software before. The new system should offer both electronic and paper delivery. | Build the Q7 consent flow and paper printing. Electronic delivery waits on the DRT answer (Part 4B, item 1). |
| H-2B and Davis-Bacon | No current clients have them. They are wanted later. | Leave the Q11 modules out of the first release. Keep the data model ready (visa class, project and classification fields). |
| DRT access | Cornerstone's owner led DRT until recently and still has contacts there. | Take the Part 4B DRT list to them first. Ask for written confirmation where possible, so the law firm can rely on it. |

---

## Sources not reachable or limited

- GuamTax pages state no 1099 or W-2GU deadlines. Dates come from Tax Alert 23-01 (tax year 2023) and the IRS 2026 W-2 instructions.
- I could not read the official eCFR (redirected). Federal regulation text came from Cornell LII, which mirrors the eCFR.
- The Guam breach statute text is the 2009 compilation (COL 052809). I found no amendments, but confirm with the current Compiler edition.

### W-4 effective date audit

Run this read-only query with an authorized reporting connection to find records
whose effective date precedes their recorded signature date.

```sql
SELECT id, company_id, source, effective_on, w4_signed_on
FROM employee_w4_elections
WHERE effective_on < w4_signed_on
ORDER BY company_id, effective_on, id;
```
