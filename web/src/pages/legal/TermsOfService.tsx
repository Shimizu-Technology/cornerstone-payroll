import { Link } from 'react-router';
import { LegalLayout, LegalList, LegalSection } from './LegalLayout';

export function TermsOfService() {
  return (
    <LegalLayout
      title="Terms of Service"
      intro={
        <>
          <p>
            These terms cover your use of Cornerstone Payroll, the payroll software that Shimizu Technology builds and
            operates at payroll.shimizu-technology.com. In these terms, "we" and "us" mean Shimizu Technology.
            Cornerstone Accounting and Business Management ("Cornerstone") uses the software to provide payroll
            services to its clients.
          </p>
          <p className="mt-4">
            By using the software, you agree to these terms. If your organization has a written agreement with
            Cornerstone or with us, that agreement controls wherever it differs from these terms.
          </p>
        </>
      }
    >
      <LegalSection id="access" title="Who can use the software">
        <p>
          Access is by invitation only. You may use the software only if your organization, or Cornerstone, has invited
          you and you are acting for that organization.
        </p>
      </LegalSection>

      <LegalSection id="accounts" title="Your account">
        <LegalList>
          <li>keep your sign-in details to yourself and do not share your account;</li>
          <li>use two-step sign-in when it is required for your account;</li>
          <li>tell us right away if you think someone else has used your account.</li>
        </LegalList>
        <p>We may suspend an account to protect the service or the people whose information it holds.</p>
      </LegalSection>

      <LegalSection id="acceptable-use" title="Acceptable use">
        <p>You agree not to:</p>
        <LegalList>
          <li>access or try to access any company's information that you have not been given access to;</li>
          <li>try to get around security controls, or test the software's security without our written permission;</li>
          <li>overload, disrupt, copy, or reverse engineer the software;</li>
          <li>upload malicious files or content you have no right to share;</li>
          <li>use the software in a way that breaks the law.</li>
        </LegalList>
      </LegalSection>

      <LegalSection id="your-information" title="Your organization's information">
        <p>
          Your organization owns the information it puts into the software. It is responsible for that information being
          accurate and for having the right to provide it, including information about its employees. You allow us to use
          the information only to provide and support the service, as described in our{' '}
          <Link to="/privacy" className="font-semibold text-primary-800 underline underline-offset-4">Privacy Policy</Link>.
        </p>
      </LegalSection>

      <LegalSection id="payroll-results" title="Payroll results and professional services">
        <p>
          The software calculates payroll from the information and settings it is given. Cornerstone reviews payroll as
          part of the services it provides under its agreement with each client. The software itself does not give tax,
          legal, or accounting advice.
        </p>
        <p>
          Unless your organization's written agreement says otherwise, your organization remains responsible for paying
          wages and taxes on time and for the accuracy of the information it provides.
        </p>
      </LegalSection>

      <LegalSection id="availability" title="Availability and changes">
        <p>
          We work to keep the software available and to plan maintenance outside payroll deadlines, but we cannot promise
          it will always be available or free of errors. We may add, change, or remove features. If a change materially
          affects how your organization uses the software, we will tell your organization ahead of time.
        </p>
      </LegalSection>

      <LegalSection id="ownership" title="Ownership of the software">
        <p>
          The software belongs to Shimizu Technology. These terms let you use it for your organization's payroll. They do
          not give you any other rights in the software.
        </p>
      </LegalSection>

      <LegalSection id="ending" title="Ending access">
        <p>
          Your organization can stop using the software at any time. We may suspend or end access for anyone who breaks
          these terms. After access ends, we keep and delete information as our Privacy Policy and your organization's
          written agreement describe.
        </p>
      </LegalSection>

      <LegalSection id="liability" title="Limits on our responsibility">
        <p>
          Unless your organization's written agreement says otherwise, and to the extent the law allows, the software is
          provided as it is, and we are not responsible for indirect or consequential losses arising from its use. Nothing
          in these terms limits any responsibility that cannot be limited by law.
        </p>
      </LegalSection>

      <LegalSection id="law" title="Governing law">
        <p>These terms are governed by the laws of Guam.</p>
      </LegalSection>

      <LegalSection id="changes" title="Changes to these terms">
        <p>
          We will post any changes on this page and update the date at the top. If a change is material, we will also
          notify our clients. Continuing to use the software after a change means you accept the updated terms.
        </p>
      </LegalSection>

      <LegalSection id="contact" title="Contact">
        <p>
          Shimizu Technology,{' '}
          <a href="mailto:shimizutechnology@gmail.com" className="font-semibold text-primary-800 underline underline-offset-4">
            shimizutechnology@gmail.com
          </a>
          , 671-483-0219.
        </p>
      </LegalSection>
    </LegalLayout>
  );
}
