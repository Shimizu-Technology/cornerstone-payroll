# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactValidator do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, first_name: "Emma", last_name: "Mercer", email: nil, phone: nil) }

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
        email: "  Emma.Mercer@Example.COM ",
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

    it "blocks structural placeholder emails" do
      %w[noemail@example.com none@example.com noreply@example.com worker@noemail.com].each do |placeholder|
        result = described_class.call(employee: employee, company: company, email: placeholder)
        expect(result).not_to be_valid
        expect(result.errors[:email].first).to match(/placeholder/i)
      end
    end

    it "blocks emails on the configurable placeholder list" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EMPLOYEE_PLACEHOLDER_EMAILS").and_return("shared-payroll@example.com, office-temp@example.test")

      result = described_class.call(employee: employee, company: company, email: "Shared-Payroll@example.com")

      expect(result).not_to be_valid
      expect(result.errors[:email].first).to match(/placeholder/i)
    end

    it "blocks mass-shared inbox emails detected from existing employee data" do
      other_company = create(:company, organization: company.organization)
      3.times { |i| create(:employee, company: company, first_name: "Worker#{i}", last_name: "One", email: "shared-inbox@example.com") }
      2.times { |i| create(:employee, company: other_company, first_name: "Staff#{i}", last_name: "Two", email: "shared-inbox@example.com") }

      result = described_class.call(employee: employee, company: company, email: "shared-inbox@example.com")

      expect(result).not_to be_valid
      expect(result.errors[:email].first).to match(/shared inbox/i)
    end

    it "allows the same person working at two companies without flagging as a shared inbox" do
      other_company = create(:company, organization: company.organization)
      create(:employee, company: other_company, first_name: "Emma", last_name: "Mercer", email: "emma.personal@example.com")

      result = described_class.call(employee: employee, company: company, email: "emma.personal@example.com")

      expect(result).to be_valid
      expect(result.warnings).to be_empty
    end

    it "returns a warning (not an error) when a coworker at the same company shares a family email" do
      create(:employee, company: company, first_name: "Maria", last_name: "Mercer", email: "family@example.com")

      result = described_class.call(employee: employee, company: company, email: "family@example.com")

      expect(result).to be_valid
      expect(result.warnings.size).to eq(1)
      expect(result.warnings.first).to include(code: "shared_company_email", field: "email", matching_employee_count: 1)
    end

    it "blocks another person's staff login email even if confirmation is passed" do
      create(:user, company: company, organization: company.organization, role: "admin", name: "Dafne Admin", email: "dafne.staff@example.com")

      result = described_class.call(
        employee: employee,
        company: company,
        email: "dafne.staff@example.com",
        confirm_same_person_email: true,
        actor: create(:user, company: company, organization: company.organization, role: "admin")
      )

      expect(result).not_to be_valid
      expect(result.same_person_confirmation_required?).to be(false)
      expect(result.errors[:email].first).to match(/another person's payroll login/i)
    end

    it "allows an employee's own login email when already linked via employee_account_links" do
      login_user = create(:user, company: company, organization: company.organization, role: "client", name: "Elena Mercer", email: "emma.client@example.com")
      EmployeeAccountLink.create!(company: company, employee: employee, user: login_user, status: "active")

      result = described_class.call(employee: employee, company: company, email: "emma.client@example.com")

      expect(result).to be_valid
      expect(result.same_person_confirmation_required?).to be(false)
      expect(result.same_person_confirmed?).to be(false)
    end

    it "requires explicit confirmation when an unlinked login email matches the employee's name, and allows it when confirmed" do
      client_admin = create(:user, company: company, organization: company.organization, role: "client", name: "Elena Mercer", email: "emma.client@example.com")
      CompanyAssignment.create!(user: client_admin, company: company)
      staff_actor = create(:user, company: company, organization: company.organization, role: "admin")

      unconfirmed = described_class.call(
        employee: employee,
        company: company,
        email: "emma.client@example.com",
        confirm_same_person_email: false,
        actor: staff_actor
      )
      expect(unconfirmed).not_to be_valid
      expect(unconfirmed.same_person_confirmation_required?).to be(true)

      confirmed = described_class.call(
        employee: employee,
        company: company,
        email: "emma.client@example.com",
        confirm_same_person_email: true,
        actor: staff_actor
      )
      expect(confirmed).to be_valid
      expect(confirmed.same_person_confirmed?).to be(true)
      expect(confirmed.matched_login_user).to eq(client_admin)
    end

    it "prevents a client user from confirming a staff user's login email" do
      create(:user, company: company, organization: company.organization, role: "manager", name: "Elena Mercer", email: "emma.staff@example.com")
      client_actor = create(:user, company: company, organization: company.organization, role: "client", name: "Mo Owner", email: "mo@example.com")

      result = described_class.call(
        employee: employee,
        company: company,
        email: "emma.staff@example.com",
        confirm_same_person_email: true,
        actor: client_actor
      )

      expect(result).not_to be_valid
      expect(result.same_person_confirmation_required?).to be(false)
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
      employee.update!(email: "emma.unique@example.com")

      result = described_class.validate_for_invite(employee)

      expect(result).to be_valid
    end
  end
end
