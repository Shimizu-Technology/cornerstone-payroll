import { Link } from 'react-router';
import { LegalLayout, LegalList, LegalSection } from './LegalLayout';

const serviceProviders = [
  { name: 'Clerk', purpose: 'Sign-in, invitations, and account security.' },
  { name: 'Render', purpose: 'Runs the application servers, in Singapore.' },
  { name: 'Neon', purpose: 'Hosts the database, in Singapore.' },
  { name: 'Cloudflare', purpose: 'Domain and network services, and storage for uploaded documents and generated files such as checks and reports.' },
  { name: 'Netlify', purpose: 'Hosts the website files your browser loads.' },
  { name: 'Resend', purpose: 'Sends email, such as invitations and notifications.' },
  { name: 'Google', purpose: 'Handles "Sign in with Google" if you choose to use it.' },
  {
    name: 'OpenRouter and the AI model provider it connects to',
    purpose: 'Reads hours from timecard images, or drafts invoice text, only when one of those optional features is turned on.',
  },
];

export function PrivacyPolicy() {
  return (
    <LegalLayout
      title="Privacy Policy"
      intro={
        <p>
          Cornerstone Payroll is payroll software for Guam businesses and the accounting firm that serves them. This
          policy explains what personal information the software holds, where it comes from, how it is used and shared,
          and what you can do about it.
        </p>
      }
    >
      <LegalSection id="who-we-are" title="Who we are">
        <LegalList>
          <li>
            <strong>Shimizu Technology</strong> builds and operates the Cornerstone Payroll software at
            payroll.shimizu-technology.com. In this policy, "we" and "us" mean Shimizu Technology.
          </li>
          <li>
            <strong>Cornerstone Accounting and Business Management</strong> ("Cornerstone") uses the software to provide
            payroll and accounting services to its clients.
          </li>
          <li>
            <strong>Employers</strong> that use the service (our "clients") decide which employee information to provide.
            For employee records, we and Cornerstone handle the information on the employer's behalf.
          </li>
        </LegalList>
      </LegalSection>

      <LegalSection id="information" title="Information the software holds">
        <p>About employees and contractors of our clients:</p>
        <LegalList>
          <li>name, home address, phone number, email address, and date of birth;</li>
          <li>Social Security number, or an employer identification number for contractors;</li>
          <li>pay rates, compensation history, and hours worked;</li>
          <li>tax withholding elections, such as Form W-4 details;</li>
          <li>deductions, such as retirement contributions, loan repayments, and court-ordered garnishments;</li>
          <li>bank account details, if an employer provides them for payment;</li>
          <li>payroll results: pay stubs, checks, W-2GU and 1099 forms, and other tax filings.</li>
        </LegalList>
        <p>We also hold:</p>
        <LegalList>
          <li>documents uploaded through the client portal, such as timesheets, hiring forms, and payroll files;</li>
          <li>messages exchanged between clients and Cornerstone in the portal;</li>
          <li>
            for people who sign in (Cornerstone staff and client users): name, email address, role, which companies they
            can access, and a record of sign-ins and actions, including IP address and browser details.
          </li>
        </LegalList>
      </LegalSection>

      <LegalSection id="sources" title="Where the information comes from">
        <LegalList>
          <li>employers and the staff they authorize;</li>
          <li>Cornerstone staff, who enter and review payroll information;</li>
          <li>time-tracking apps that a client chooses to connect;</li>
          <li>files from a client's previous payroll provider or accounting software, imported at the client's request.</li>
        </LegalList>
      </LegalSection>

      <LegalSection id="use" title="How we use it">
        <LegalList>
          <li>to calculate pay, withholding, and deductions, and to produce checks, pay stubs, and reports;</li>
          <li>to prepare and keep the records needed for Guam and federal tax and employment filings;</li>
          <li>to let clients and Cornerstone exchange documents and messages;</li>
          <li>to secure the service: confirm who is signing in, limit access by role, keep an audit trail, and investigate problems;</li>
          <li>to maintain and improve the software.</li>
        </LegalList>
        <p>
          We do not sell personal information and do not use it for advertising. We use tax information only to provide
          payroll services and as the law requires.
        </p>
      </LegalSection>

      <LegalSection id="sharing" title="Who we share it with">
        <p>
          Other companies run parts of the service for us. Each one receives only the information it needs for its part:
        </p>
        <div className="overflow-hidden rounded-2xl border border-neutral-900/10 bg-white/70">
          <table className="w-full text-left text-sm">
            <thead className="bg-white/80 text-xs font-extrabold uppercase tracking-wide text-neutral-500">
              <tr>
                <th scope="col" className="px-4 py-3">Provider</th>
                <th scope="col" className="px-4 py-3">What they do</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-neutral-900/10">
              {serviceProviders.map(provider => (
                <tr key={provider.name}>
                  <th scope="row" className="px-4 py-3 align-top font-semibold text-neutral-900">{provider.name}</th>
                  <td className="px-4 py-3 align-top text-neutral-700">{provider.purpose}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>We also share information:</p>
        <LegalList>
          <li>with the employer, for its own employees and payroll;</li>
          <li>with government agencies when filings require it, such as the IRS, the Social Security Administration, and the Guam Department of Revenue and Taxation;</li>
          <li>when the law requires it, for example in response to a valid court order;</li>
          <li>to protect the safety, rights, or property of people or of the service;</li>
          <li>with a buyer or successor if our business is transferred, who must keep protecting the information as this policy describes.</li>
        </LegalList>
      </LegalSection>

      <LegalSection id="cookies" title="Cookies and analytics">
        <p>
          The site uses cookies that keep you signed in. Clerk sets these cookies. We do not use advertising cookies.
        </p>
        <p>
          The software includes a product-analytics tool, PostHog, which is turned off. If we turn it on, we will update
          this policy first. It is set up without session recording and without automatically capturing what you type.
        </p>
      </LegalSection>

      <LegalSection id="security" title="How we protect it">
        <LegalList>
          <li>all connections to the service are encrypted (HTTPS);</li>
          <li>Social Security numbers and bank account details are encrypted in the database;</li>
          <li>access is limited by role and by client company, and sign-ins and changes are logged;</li>
          <li>we are rolling out two-step sign-in for staff and client users.</li>
        </LegalList>
        <p>
          No system is perfectly secure. If a security incident affects your information, we will notify the affected
          clients and people as the law requires.
        </p>
      </LegalSection>

      <LegalSection id="location" title="Where it is stored">
        <p>
          The application servers and database are in Singapore. Some service providers, such as Clerk and Resend, may
          process information in the United States or other countries. Information may therefore be stored and processed
          outside Guam.
        </p>
      </LegalSection>

      <LegalSection id="retention" title="How long we keep it">
        <p>
          We keep payroll and tax records for as long as a client uses the service, and afterward for as long as tax and
          employment law requires. Federal rules, for example, require employment tax records to be kept for at least four
          years. After that we delete the records or remove the details that identify people. Account and audit records
          follow the same approach.
        </p>
      </LegalSection>

      <LegalSection id="choices" title="Your choices">
        <LegalList>
          <li>
            <strong>Employees:</strong> your employer controls your payroll record. To see or correct your information, ask
            your employer first. You can also contact us or Cornerstone, and we will work with your employer on the
            request.
          </li>
          <li>
            <strong>People who sign in:</strong> you can ask us to correct your account details or close your account.
            Some records, such as audit logs and payroll you approved, must be kept for the periods described above.
          </li>
        </LegalList>
      </LegalSection>

      <LegalSection id="children" title="Children">
        <p>
          The service is built for businesses and is not meant to be used by children. It may hold payroll records for
          employees under 18 because their employers provide them. Those records are protected the same way as all others.
        </p>
      </LegalSection>

      <LegalSection id="changes" title="Changes to this policy">
        <p>
          We will post any changes on this page and update the date at the top. If a change materially affects how we use
          personal information, we will also notify our clients.
        </p>
      </LegalSection>

      <LegalSection id="contact" title="Contact">
        <p>
          Questions about this policy or your information: Shimizu Technology,{' '}
          <a href="mailto:shimizutechnology@gmail.com" className="font-semibold text-primary-800 underline underline-offset-4">
            shimizutechnology@gmail.com
          </a>
          , 671-483-0219.
        </p>
        <p>
          Questions about payroll services: Cornerstone Accounting and Business Management, 671-482-8671,{' '}
          <a href="https://cornerstone-accounting.tax" target="_blank" rel="noreferrer" className="font-semibold text-primary-800 underline underline-offset-4">
            cornerstone-accounting.tax
          </a>
          .
        </p>
        <p>
          See also our <Link to="/terms" className="font-semibold text-primary-800 underline underline-offset-4">Terms of Service</Link>.
        </p>
      </LegalSection>
    </LegalLayout>
  );
}
