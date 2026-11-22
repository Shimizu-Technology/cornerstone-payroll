# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeNote do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: nil) }
  let(:staff_user) { create(:user, company: company, organization: company.organization, role: :accountant) }

  describe "validations" do
    it "is valid with ordinary payroll context text" do
      note = build(
        :employee_note,
        company: company,
        employee: employee,
        created_by: staff_user,
        body: "Roke said her start date was Nov 15; the W-4 says Nov 16. Call 671-555-1234 if check #1042 needs reissue."
      )

      expect(note).to be_valid
    end

    it "requires a non-blank body and enforces the maximum length" do
      blank_note = build(:employee_note, company: company, employee: employee, created_by: staff_user, body: "   ")
      expect(blank_note).not_to be_valid
      expect(blank_note.errors[:body]).to include("can't be blank")

      oversized_note = build(
        :employee_note,
        company: company,
        employee: employee,
        created_by: staff_user,
        body: "a" * (described_class::MAX_BODY_LENGTH + 1)
      )
      expect(oversized_note).not_to be_valid
      expect(oversized_note.errors[:body].join(" ")).to match(/too long/i)
    end

    it "requires the company to match the employee's company" do
      other_company = create(:company, organization: company.organization)
      note = build(:employee_note, company: other_company, employee: employee, created_by: staff_user)

      expect(note).not_to be_valid
      expect(note.errors[:company]).to include("must match the employee's company")
    end

    it "rejects SSN-like patterns with or without dashes" do
      dashed = build(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Employee SSN is 123-45-6789")
      expect(dashed).not_to be_valid
      expect(dashed.errors[:body].join(" ")).to match(/SSN/i)

      plain = build(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Tax ID 123456789 on form")
      expect(plain).not_to be_valid
      expect(plain.errors[:body].join(" ")).to match(/SSN/i)
    end

    it "rejects long digit runs that look like bank account or card numbers" do
      account_number = build(
        :employee_note,
        company: company,
        employee: employee,
        created_by: staff_user,
        body: "Direct deposit account 123456789012"
      )
      expect(account_number).not_to be_valid
      expect(account_number.errors[:body].join(" ")).to match(/bank account or card number/i)

      card_number = build(
        :employee_note,
        company: company,
        employee: employee,
        created_by: staff_user,
        body: "Card 4111-1111-1111-1111 on file"
      )
      expect(card_number).not_to be_valid
      expect(card_number.errors[:body].join(" ")).to match(/bank account or card number/i)
    end
  end

  describe "append-only behavior and hiding" do
    let!(:note) do
      create(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Original note")
    end

    it "prevents editing the body or core ownership attributes" do
      expect(note.update(body: "Edited note")).to be(false)
      expect(note.errors[:body]).to include("cannot be edited; add a new note instead")
      expect(note.reload.body).to eq("Original note")

      other_user = create(:user, company: company, organization: company.organization, role: :manager)
      expect(note.update(created_by: other_user)).to be(false)
      expect(note.errors[:created_by_id]).to include("cannot be changed after creation")
    end

    it "prevents hard deletion" do
      expect(note.destroy).to be(false)
      expect(note.errors[:base]).to include("Employee notes cannot be deleted; hide the note instead")
      expect(described_class.exists?(note.id)).to be(true)
    end

    it "requires a reason to hide a note and prevents further changes once hidden" do
      expect {
        note.hide!(actor: staff_user, reason: "   ")
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(note.errors[:hidden_reason]).to include("is required to hide a note")
      expect(note.reload).not_to be_hidden

      note.hide!(actor: staff_user, reason: "Posted to wrong employee")
      expect(note.reload).to be_hidden
      expect(note.hidden_by).to eq(staff_user)
      expect(note.hidden_reason).to eq("Posted to wrong employee")

      expect {
        note.hide!(actor: staff_user, reason: "Another reason")
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(note.update(hidden_reason: "Changed reason")).to be(false)
      expect(note.reload.hidden_reason).to eq("Posted to wrong employee")
    end
  end

  describe "test workspace setup cloning" do
    it "does not copy staff notes into cloned test workspaces" do
      create(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Live operator context")
      test_workspace = create(
        :company,
        organization: company.organization,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        migration_source_company: company,
        migration_rehearsal_status: "ready"
      )
      admin = create(:user, company: company, organization: company.organization, role: :admin)

      result = TestWorkspace::SetupCloner.new(
        source_company: company,
        target_company: test_workspace,
        actor: admin
      ).call

      cloned_employee = result.fetch(:employees).fetch(employee.id)
      expect(cloned_employee.employee_notes).to be_empty
      expect(described_class.where(company: test_workspace)).to be_empty
    end
  end
end
