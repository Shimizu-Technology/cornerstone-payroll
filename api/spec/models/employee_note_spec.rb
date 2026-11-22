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

    describe "sensitive-data detection (table-driven)" do
      [
        [ "dashed SSN", "Employee SSN is 123-45-6789.", /SSN/i ],
        [ "space-separated SSN", "Verified 123 45 6789 on form", /SSN/i ],
        [ "dot-separated SSN", "Listed as 123.45.6789 on intake", /SSN/i ],
        [ "glued SSN prefix + 9 digits", "SSN123456789", /SSN/i ],
        [ "SSN label + bare 9 digits", "SSN: 123456789", /SSN/i ],
        [ "SSN no. + bare 9 digits", "SSN no. 987654321", /SSN/i ],
        [ "SSN + newline + bare 9 digits", "SSN:\n987654321", /SSN/i ],
        [ "Tax ID label + bare 9 digits", "Tax ID 123456789 on W-4", /SSN/i ],
        [ "bare 9 digits followed by SSN label", "123456789 (SSN)", /SSN/i ],
        [ "10-digit account near acct", "Direct deposit acct 1234567890", /bank account or card number/i ],
        [ "Acct no. + 10-digit account", "Acct no. 1234567890", /bank account or card number/i ],
        [ "Account #: + 10-digit account", "Account #: 1234567890", /bank account or card number/i ],
        [ "DD acct ending + 10-digit account", "DD acct ending 1234567890", /bank account or card number/i ],
        [ "10-digit 671 number directly after account keyword", "Acct no. 6715551234", /bank account or card number/i ],
        [ "12-digit account near account", "Direct deposit account 123456789012", /bank account or card number/i ],
        [ "17-digit account near DD", "DD #12345678901234567", /bank account or card number/i ],
        [ "11-digit account near bank", "Bank 12345678901", /bank account or card number/i ],
        [ "9-digit routing near routing", "Routing 021000021 for payroll", /bank account or card number/i ],
        [ "routing no. + 9-digit routing", "routing no. 121000358", /bank account or card number/i ],
        [ "10-digit number near routing", "routing # 1234567890", /bank account or card number/i ],
        [ "card 4-4-4-4 hyphenated", "Card 4111-1111-1111-1111 on file", /bank account or card number/i ],
        [ "card 4-4-4-4 spaced", "Card 4111 1111 1111 1111 on file", /bank account or card number/i ],
        [ "card 4-6-5 hyphenated (Amex)", "Amex 3782-822463-10005", /bank account or card number/i ],
        [ "card 4-6-5 spaced (Amex)", "Amex 3782 822463 10005", /bank account or card number/i ],
        [ "card 4-6-4 spaced (Diners)", "Diners card 3056 930902 5904", /bank account or card number/i ],
        [ "hyphenated SSN label", "SSN-123-45-6789", /SSN/i ],
        [ "account label after a phone-shaped number", "6715551234 is the account number", /bank account or card number/i ],
        [ "no-break space in Social Security label", "Social\u00A0security 987654321", /SSN/i ],
        [ "card 4-4-4-4-3 hyphenated (19 digits)", "4111-1111-1111-1111-123", /bank account or card number/i ],
        [ "bare 13-digit card", "4111111111111", /bank account or card number/i ],
        [ "bare 16-digit card", "4111111111111111", /bank account or card number/i ],
        [ "bare 19-digit card", "4111111111111111111", /bank account or card number/i ]
      ].each do |label, sample_body, expected_error|
        it "rejects #{label}" do
          note = build(:employee_note, company: company, employee: employee, created_by: staff_user, body: sample_body)

          expect(note).not_to be_valid
          expect(note.errors[:body].join(" ")).to match(expected_error)
        end
      end

      [
        [ "Guam ZIP+4", "Mailing address Tamuning, GU 96913-2716." ],
        [ "generic ZIP+4", "Updated ZIP to 12345-6789 per employee." ],
        [ "dashed EIN", "Employer EIN 66-0970313 confirmed on W-2." ],
        [ "bare EIN without dash", "Company EIN 660970313 verified on notice." ],
        [ "standalone bare 9-digit reference", "Reference 660970313 confirmed with client." ],
        [ "hyphenated Guam phone", "Call 671-555-1234 about missing hours." ],
        [ "parenthesized Guam phone", "Phone (671) 555-1234 confirmed." ],
        [ "bare 10-digit Guam phone", "Reached employee at 6715551234." ],
        [ "bare Guam phone before direct deposit wording", "Called Maria at 6715551234 re: direct deposit change" ],
        [ "bare Guam phone after bank name", "Bank of Guam called from 6714721234" ],
        [ "consecutive 4-digit years", "W-2s for 2024 2025 2026 still missing" ],
        [ "consecutive 5-digit ZIP codes", "ZIPs 96913 96910 96929" ],
        [ "4-4-4 reference code", "Ref 2026 1122 0001" ],
        [ "ISO dates and adjacent date range", "Pay period 2026-11-22 2026-11-29 reviewed on 11/22/2026." ],
        [ "money amounts", "Bonus $1,234,567.89 adjusted by $45.50 after review." ],
        [ "check number", "Reissued check #1042 after stop-payment." ],
        [ "mixed separator 3-2-4", "Code 123-45 6789 is not an SSN format." ],
        [ "semicolon clause boundary", "Updated SSN; reference 660970313." ]
      ].each do |label, sample_body|
        it "accepts #{label}" do
          note = build(:employee_note, company: company, employee: employee, created_by: staff_user, body: sample_body)

          expect(note).to be_valid
        end
      end
    end

    it "rejects sensitive data in hidden_reason when hiding, while skipping body re-check on hide" do
      note = create(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Initial payroll note")

      expect {
        note.hide!(actor: staff_user, reason: "Contained SSN 987-65-4321, acct 1234567890")
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(note.errors[:hidden_reason].join(" ")).to match(/SSN/i)
      expect(note.reload).not_to be_hidden

      expect {
        note.hide!(actor: staff_user, reason: "Moved to acct no. 1234567890")
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(note.errors[:hidden_reason].join(" ")).to match(/bank account or card number/i)
      expect(note.reload).not_to be_hidden

      # A legacy note whose body would now fail the create-time check can still be
      # hidden with a clean reason because body is only checked on create.
      inserted_id = described_class.insert!(
        {
          company_id: company.id,
          employee_id: employee.id,
          created_by_id: staff_user.id,
          body: "Legacy row with SSN 987-65-4321",
          created_at: Time.current,
          updated_at: Time.current
        }
      ).rows.first.first
      legacy_note = described_class.find(inserted_id)

      expect {
        legacy_note.hide!(actor: staff_user, reason: "Contained sensitive data; hidden")
      }.not_to raise_error
      expect(legacy_note.reload).to be_hidden
    end
  end

  describe "append-only behavior, hiding, and PostgreSQL integrity guards" do
    let!(:note) do
      create(:employee_note, company: company, employee: employee, created_by: staff_user, body: "Original note")
    end

    it "prevents editing the body or core ownership attributes at the model layer" do
      expect(note.update(body: "Edited note")).to be(false)
      expect(note.errors[:body]).to include("cannot be edited; add a new note instead")
      expect(note.reload.body).to eq("Original note")

      other_user = create(:user, company: company, organization: company.organization, role: :manager)
      expect(note.update(created_by: other_user)).to be(false)
      expect(note.errors[:created_by_id]).to include("cannot be changed after creation")
    end

    it "prevents hard deletion at the model layer" do
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

    it "enforces append-only updates and no deletes via PostgreSQL triggers even when bypassing validations" do
      other_company = create(:company, organization: company.organization)
      other_employee = create(:employee, company: company, department: nil)
      other_user = create(:user, company: company, organization: company.organization, role: :manager)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(body: "Tampered body") }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(company_id: other_company.id) }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(employee_id: other_employee.id) }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(created_by_id: other_user.id) }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(created_at: 1.day.ago) }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { described_class.where(id: note.id).delete_all }
      }.to raise_error(ActiveRecord::StatementInvalid, /cannot be deleted/i)

      note.reload
      note.hide!(actor: staff_user, reason: "Duplicate")

      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(hidden_reason: "Altered reason") }
      }.to raise_error(ActiveRecord::StatementInvalid, /Hidden employee notes cannot be modified/i)
      expect {
        ActiveRecord::Base.transaction(requires_new: true) { note.update_columns(hidden_at: nil, hidden_by_id: nil, hidden_reason: nil) }
      }.to raise_error(ActiveRecord::StatementInvalid, /Hidden employee notes cannot be modified/i)
      expect(note.reload.body).to eq("Original note")
      expect(note.hidden_reason).to eq("Duplicate")
    end

    it "enforces body length and hidden-field consistency CHECK constraints in PostgreSQL" do
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.insert!(
            {
              company_id: company.id,
              employee_id: employee.id,
              created_by_id: staff_user.id,
              body: "   ",
              created_at: Time.current,
              updated_at: Time.current
            }
          )
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /employee_notes_body_length/)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.insert!(
            {
              company_id: company.id,
              employee_id: employee.id,
              created_by_id: staff_user.id,
              body: "a" * 2001,
              created_at: Time.current,
              updated_at: Time.current
            }
          )
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /employee_notes_body_length/)

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          note.update_columns(hidden_at: Time.current, hidden_by_id: nil, hidden_reason: nil)
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /employee_notes_hidden_fields_consistent/)
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
