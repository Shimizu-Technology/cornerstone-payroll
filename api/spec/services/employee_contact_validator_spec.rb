# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactValidator do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:employee) { create(:employee, company: company, first_name: "Elena", last_name: "Mercer", email: nil, phone: nil) }

  describe ".normalize_phone" do
    it "defaults 7-digit Guam numbers to +1 671" do
      expect(described_class.normalize_phone("555-0199")).to eq([ "+16715550199", nil ])
      expect(described_class.normalize_phone("5550199")).to eq([ "+16715550199", nil ])
    end

    it "normalizes 10-digit and 11-digit NANP numbers to E.164" do
      expect(described_class.normalize_phone("(671) 555-0199")).to eq([ "+16715550199", nil ])
      expect(described_class.normalize_phone("415.555.0199")).to eq([ "+14155550199", nil ])
      expect(described_class.normalize_phone("1-671-555-0199")).to eq([ "+16715550199", nil ])
      expect(described_class.normalize_phone("+1 671 555 0199")).to eq([ "+16715550199", nil ])
    end

    it "normalizes valid international E.164 numbers" do
      expect(described_class.normalize_phone("+63 917 555 0100")).to eq([ "+639175550100", nil ])
    end

    it "rejects invalid phone numbers" do
      expect(described_class.normalize_phone("12345").last).to be_present
      expect(described_class.normalize_phone("671-555-abcd").last).to be_present
      expect(described_class.normalize_phone("000-0000").last).to be_present
      expect(described_class.normalize_phone("+1671555").last).to be_present
    end

    it "rejects North American numbers whose area code or exchange starts with 0 or 1" do
      [ "1234567", "0555019", "671-155-0199", "(171) 555-0199", "071-555-0199", "+1 671 055 0199", "1-271-155-0199" ].each do |raw|
        expect(described_class.normalize_phone(raw).first).to be_nil, "expected #{raw} to be rejected"
      end
      expect(described_class.normalize_phone("2345678")).to eq([ "+16712345678", nil ])
      expect(described_class.normalize_phone("+1 271 255 0199")).to eq([ "+12712550199", nil ])
    end

    it "allows blank phones" do
      expect(described_class.normalize_phone("")).to eq([ nil, nil ])
      expect(described_class.normalize_phone(nil)).to eq([ nil, nil ])
    end
  end

  describe "#call" do
    it "normalizes valid email and Guam phone" do
      result = described_class.call(
        employee: employee,
        company: company,
        email: "  Elena.Mercer@Example.COM ",
        phone: "555-0142"
      )

      expect(result).to be_valid
      expect(result.normalized_email).to eq("elena.mercer@example.com")
      expect(result.normalized_phone).to eq("+16715550142")
      expect(result.warnings).to be_empty
    end

    it "rejects invalid email formats" do
      %w[not-an-email missing@domain user..name@example.com user@localhost].each do |bad_email|
        result = described_class.call(employee: employee, company: company, email: bad_email)
        expect(result).not_to be_valid
        expect(result.errors[:email]).to include(/valid email/i)
      end
    end

    it "warns on unmarked structural placeholder emails without blocking" do
      %w[noemail@example.com none@example.com noreply@example.com worker@noemail.com].each do |placeholder|
        result = described_class.call(employee: employee, company: company, email: placeholder)
        expect(result).to be_valid
        expect(result.warnings.map { |w| w[:code] }).to include("placeholder_email_pattern")
      end
    end

    it "blocks emails on the configured or staff-marked placeholder list" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EMPLOYEE_PLACEHOLDER_EMAILS").and_return("shared-payroll@example.com")
      EmployeePlaceholderEmail.create!(organization: organization, email: "mosa-office@example.com")

      env_result = described_class.call(employee: employee, company: company, email: "Shared-Payroll@example.com")
      expect(env_result).not_to be_valid
      expect(env_result.errors[:email].first).to match(/placeholder/i)

      db_result = described_class.call(employee: employee, company: company, email: "Mosa-Office@example.com")
      expect(db_result).not_to be_valid
      expect(db_result.errors[:email].first).to match(/placeholder/i)
    end

    it "keeps unmarked same-company duplicates warning-only even when 5 or more employees share the family email" do
      5.times { |i| create(:employee, company: company, first_name: "Family#{i}", last_name: "Mercer", email: "family@example.com") }

      result = described_class.call(employee: employee, company: company, email: "family@example.com")

      expect(result).to be_valid
      expect(result.warnings.size).to eq(1)
      expect(result.warnings.first).to include(code: "shared_company_email", field: "email", matching_employee_count: 5)
    end

    it "counts a coworker whose stored email has a trailing tab or newline, as normalize_email does" do
      coworker = create(:employee, company: company, first_name: "Ana", last_name: "Family", email: "x@example.com")
      coworker.update_column(:email, " Family@Example.com\t\n")

      result = described_class.call(employee: employee, company: company, email: "family@example.com")
      expect(result.warnings.map { |warning| warning[:code] }).to eq([ "shared_company_email" ])

      employee.update!(email: "family@example.com")
      expect(described_class.validate_for_invite(employee)).not_to be_valid
    end

    it "does not strip a letter v from the ends of an email in SQL comparisons" do
      create(:employee, company: company, first_name: "Dav", last_name: "Coworker", email: "vda@example.cov")

      result = described_class.call(employee: employee, company: company, email: "da@example.co")
      expect(result.warnings).to be_empty
    end

    it "allows an employee's own login email when already linked via employee_account_links" do
      login_user = create(:user, company: company, organization: organization, role: "client", name: "Different Display Name", email: "elena.client@example.com")
      EmployeeAccountLink.create!(company: company, employee: employee, user: login_user, status: "active")

      result = described_class.call(employee: employee, company: company, email: "elena.client@example.com")

      expect(result).to be_valid
      expect(result.same_person_confirmation_required?).to be(false)
      expect(result.same_person_confirmed?).to be(false)
    end

    it "always rejects a login linked to a different employee even with confirmation" do
      other_employee = create(:employee, company: company, first_name: "Other", last_name: "Worker")
      login_user = create(:user, company: company, organization: organization, role: "client", name: "Elena Mercer", email: "elena.linked@example.com")
      EmployeeAccountLink.create!(company: company, employee: other_employee, user: login_user, status: "active")
      staff_actor = create(:user, company: company, organization: organization, role: "admin")

      staff_result = described_class.call(
        employee: employee,
        company: company,
        email: "elena.linked@example.com",
        confirm_same_person_email: true,
        actor: staff_actor
      )
      expect(staff_result).not_to be_valid
      expect(staff_result.same_person_confirmation_required?).to be(false)
      expect(staff_result.errors[:email].first).to match(/already linked to another employee/i)

      self_result = described_class.call(
        employee: employee,
        company: company,
        email: "elena.linked@example.com",
        confirm_same_person_email: true,
        actor: login_user
      )
      expect(self_result).not_to be_valid
      expect(self_result.same_person_confirmation_required?).to be(false)
      expect(self_result.login_email_rejected?).to be(true)
      expect(self_result.errors[:email]).to eq([ described_class::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
    end

    it "checks conflicting links first and rejects when a login is linked to both this employee and another employee (including across companies under company TenantScope)" do
      other_company = create(:company, organization: organization)
      other_company_employee = create(:employee, company: other_company, first_name: "Other", last_name: "TenantWorker")
      login_user = create(:user, company: company, organization: organization, role: "client", name: "Elena Mercer", email: "elena.dual@example.com")
      EmployeeAccountLink.create!(company: company, employee: employee, user: login_user, status: "active")
      EmployeeAccountLink.create!(company: other_company, employee: other_company_employee, user: login_user, status: "active")

      decision = TenantScope.with_company(company.id) do
        EmployeeAccountLink.contact_email_link_decision(
          user_id: login_user.id,
          company_id: company.id,
          allowed_employee_ids: [ employee.id ]
        )
      end
      expect(decision).to eq(:conflict)

      result = TenantScope.with_company(company.id) do
        described_class.call(
          employee: employee,
          company: company,
          email: "elena.dual@example.com",
          confirm_same_person_email: true,
          actor: login_user
        )
      end
      expect(result).not_to be_valid
      expect(result.login_email_rejected?).to be(true)
      expect(result.errors[:email]).to eq([ described_class::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
    end

    it "detects a conflicting link in another company even inside TenantScope.with_company" do
      other_company = create(:company, organization: organization)
      other_company_employee = create(:employee, company: other_company, first_name: "Other", last_name: "Worker")
      login_user = create(:user, company: other_company, organization: organization, role: "client", name: "Cross Co", email: "cross.co@example.com")
      EmployeeAccountLink.create!(company: other_company, employee: other_company_employee, user: login_user, status: "active")
      staff_actor = create(:user, company: company, organization: organization, role: "admin")

      result = TenantScope.with_company(company.id) do
        described_class.call(
          employee: employee,
          company: company,
          email: "cross.co@example.com",
          confirm_same_person_email: true,
          actor: staff_actor
        )
      end

      expect(result).not_to be_valid
      expect(result.login_email_rejected?).to be(true)
      expect(result.errors[:email].first).to match(/already linked to another employee/i)
    end

    it "rejects a client name-match attempt on another person's login with the generic client error" do
      # Same name as employee, but a different login than client_actor.
      other_client = create(:user, company: company, organization: organization, role: "client", name: "Elena Mercer", email: "elena.other@example.com")
      CompanyAssignment.create!(user: other_client, company: company)
      client_actor = create(:user, company: company, organization: organization, role: "client", name: "Morgan Owner", email: "morgan@example.com")

      result = described_class.call(
        employee: employee,
        company: company,
        email: "elena.other@example.com",
        confirm_same_person_email: true,
        actor: client_actor
      )

      expect(result).not_to be_valid
      expect(result.same_person_confirmation_required?).to be(false)
      expect(result.errors[:email]).to eq([ described_class::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
    end

    it "allows the signed-in user's own login email when they explicitly confirm 'this is me'" do
      # Case, accents and spacing don't matter; a middle name on the login is fine.
      client_actor = create(:user, company: company, organization: organization, role: "client", name: "  ÉLENA   Rose mercer ", email: "self.client@example.com")

      unconfirmed = described_class.call(
        employee: employee,
        company: company,
        email: "self.client@example.com",
        confirm_same_person_email: false,
        actor: client_actor
      )
      expect(unconfirmed).not_to be_valid
      expect(unconfirmed.same_person_confirmation_required?).to be(true)

      confirmed = described_class.call(
        employee: employee,
        company: company,
        email: "self.client@example.com",
        confirm_same_person_email: true,
        actor: client_actor
      )
      expect(confirmed).to be_valid
      expect(confirmed.same_person_confirmed?).to be(true)
      expect(confirmed.confirmation_basis).to eq("self_confirmed")
      expect(confirmed.matched_login_user).to eq(client_actor)
    end

    it "matches a login name with a recognized suffix against the employee's stored suffix" do
      jose = create(:employee, company: company, first_name: "José", middle_name: "Manuel", last_name: "de la Cruz", name_suffix: "JR", email: nil)
      confirm = lambda do |name, target = jose|
        login = create(:user, company: company, organization: organization, role: "client", name: name, email: "#{SecureRandom.hex(4)}@example.com")
        described_class.call(employee: target, company: company, email: login.email, confirm_same_person_email: true, actor: login)
      end

      expect(confirm.call("José Manuel de la Cruz Jr.")).to be_valid
      expect(confirm.call("jose de la cruz")).to be_valid
      expect(confirm.call("José Manuel de la Cruz III")).not_to be_valid
      senior = create(:employee, company: company, first_name: "José", last_name: "de la Cruz", name_suffix: nil, email: nil)
      expect(confirm.call("José de la Cruz Sr.", senior)).not_to be_valid
      # A name with nothing comparable left (users always have some name) fails.
      expect(confirm.call("...")).not_to be_valid
    end

    it "refuses a same-person confirmation when the login's name doesn't match the employee, on both paths" do
      self_actor = create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner", email: "sloane.self@example.com")
      self_result = described_class.call(employee: employee, company: company, email: self_actor.email, confirm_same_person_email: true, actor: self_actor)
      expect(self_result).not_to be_valid
      expect(self_result.same_person_confirmed?).to be(false)
      expect(self_result).to have_attributes(login_email_rejected: true, login_email_rejection_reason: "login_name_mismatch")
      expect(self_result.errors[:email]).to eq([ described_class::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])

      other_login = create(:user, company: company, organization: organization, role: "client", name: "Elena Cruz", email: "elena.cruz@example.com")
      admin_actor = create(:user, company: company, organization: organization, role: "admin")
      staff_result = described_class.call(employee: employee, company: company, email: other_login.email, confirm_same_person_email: true, actor: admin_actor)
      expect(staff_result).not_to be_valid
      expect(staff_result.same_person_confirmation_required?).to be(false)
      expect(staff_result.errors[:email]).to eq([ described_class::LOGIN_NAME_MISMATCH_ERROR ])

      # Renaming the employee in the same save doesn't create a match.
      employee.first_name = "Sloane"
      employee.last_name = "Owner"
      expect(described_class.call(employee: employee, company: company, email: self_actor.email, confirm_same_person_email: true, actor: self_actor)).not_to be_valid
    end

    it "tells only staff who may confirm an identity why a login email was refused" do
      linked = create(:user, company: company, organization: organization, role: "client", name: "Elena Mercer", email: "elena.linked@example.com")
      EmployeeAccountLink.create!(company: company, employee: create(:employee, company: company), user: linked, status: "active")
      admin_actor = create(:user, company: company, organization: organization, role: "admin")
      accountant_actor = create(:user, company: company, organization: organization, role: "accountant")
      CompanyAssignment.create!(user: accountant_actor, company: company, client_management: false)

      admin_result = described_class.call(employee: employee, company: company, email: linked.email, actor: admin_actor)
      expect(admin_result.errors[:email].first).to match(/already linked to another employee/)

      accountant_result = described_class.call(employee: employee, company: company, email: linked.email, actor: accountant_actor)
      expect(accountant_result.errors[:email]).to eq([ described_class::CLIENT_GENERIC_LOGIN_EMAIL_ERROR ])
      expect(accountant_result.login_email_rejection_reason).to eq("linked_to_other_employee")
    end

    it "allows staff with manage_client_configuration to confirm an unlinked login, and rejects accountants without it" do
      client_login = create(:user, company: company, organization: organization, role: "client", name: "Elena Mercer", email: "elena.login@example.com")
      admin_actor = create(:user, company: company, organization: organization, role: "admin")
      accountant_actor = create(:user, company: company, organization: organization, role: "accountant")
      CompanyAssignment.create!(user: accountant_actor, company: company, client_management: false)

      unconfirmed = described_class.call(
        employee: employee,
        company: company,
        email: client_login.email,
        confirm_same_person_email: false,
        actor: admin_actor
      )
      expect(unconfirmed).not_to be_valid
      expect(unconfirmed.same_person_confirmation_required?).to be(true)
      expect(unconfirmed.errors[:email].first).to include("Elena Mercer")

      confirmed = described_class.call(
        employee: employee,
        company: company,
        email: client_login.email,
        confirm_same_person_email: true,
        actor: admin_actor
      )
      expect(confirmed).to be_valid
      expect(confirmed.same_person_confirmed?).to be(true)
      expect(confirmed.confirmation_basis).to eq("staff_confirmed")

      accountant_result = described_class.call(
        employee: employee,
        company: company,
        email: client_login.email,
        confirm_same_person_email: true,
        actor: accountant_actor
      )
      expect(accountant_result).not_to be_valid
      expect(accountant_result.same_person_confirmation_required?).to be(false)
    end
  end

  describe ".record_same_person_confirmation_audit!" do
    it "keeps an earlier operation's audit flag when no confirmation was recorded" do
      Current.domain_audit_recorded = true
      unconfirmed = described_class.call(employee: employee, company: company, email: "own@example.com")

      expect do
        described_class.record_same_person_confirmation_audit!(employee: employee, result: unconfirmed, actor: nil, company: company)
      end.not_to change(AuditLog, :count)
      expect(Current.domain_audit_recorded).to be(true)
    ensure
      Current.reset
    end
  end

  describe ".validate_for_invite" do
    it "rejects shared coworker emails for email invites" do
      create(:employee, company: company, email: "family@example.com")
      employee.update!(email: "family@example.com")

      result = described_class.validate_for_invite(employee)

      expect(result).not_to be_valid
      expect(result.errors[:email].join(" ")).to match(/cannot be used for an email invite/i)
    end

    it "accepts a unique personal email for invites" do
      employee.update!(email: "elena.unique@example.com")

      result = described_class.validate_for_invite(employee)

      expect(result).to be_valid
    end
  end
end
