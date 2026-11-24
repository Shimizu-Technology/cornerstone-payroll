# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientProfitability::LinkQueue do
  let(:organization) { create(:organization) }
  let(:practice_company) { create(:company, organization: organization, name: "Practice Co") }
  let(:settings) do
    ClientProfitabilitySetting.for(organization).tap do |setting|
      setting.update!(practice_company: practice_company)
    end
  end

  let!(:unique_staff) { create(:employee, company: practice_company, first_name: "Benjo", last_name: "Cruz", email: "benjo@example.com", status: "active") }
  let!(:inactive_only_staff) { create(:employee, company: practice_company, first_name: "Former", last_name: "Staff", email: "former.staff@example.com", status: "inactive") }
  let!(:active_rehire) { create(:employee, company: practice_company, first_name: "Mark", last_name: "Active", email: "mark.rehire@example.com", status: "active") }
  let!(:inactive_prior) { create(:employee, company: practice_company, first_name: "Mark", last_name: "Former", email: "mark.rehire@example.com", status: "terminated") }
  let!(:shared_staff_a) { create(:employee, company: practice_company, first_name: "Ana", last_name: "Reyes", email: "shared-office@example.com", status: "active") }
  let!(:shared_staff_b) { create(:employee, company: practice_company, first_name: "Carlos", last_name: "Santos", email: "shared-office@example.com", status: "active") }
  let!(:placeholder_staff) { create(:employee, company: practice_company, first_name: "Maria", last_name: "Flores", email: "noemail@example.com", status: "active") }

  before do
    import = WorkHourImport.create!(
      organization: organization,
      status: "succeeded",
      range_start: Date.new(2026, 11, 1),
      range_end: Date.new(2026, 11, 30)
    )
    [
      [ 101, "benjo@example.com", 2.0 ],
      [ 102, "shared-office@example.com", 3.0 ],
      [ 103, "noemail@example.com", 1.5 ],
      [ 104, "former.staff@example.com", 2.5 ],
      [ 105, "mark.rehire@example.com", 4.0 ]
    ].each do |tax_user_id, email, hours|
      WorkHourRow.create!(
        organization: organization,
        work_hour_import: import,
        tax_user_id: tax_user_id,
        email: email,
        client_name: "Client A",
        approval_state: "approved",
        work_date: Date.new(2026, 11, 10),
        hours: hours
      )
    end
  end

  it "uses active employees only for exact email suggestions while keeping historical records in manual selection options" do
    result = described_class.new(organization: organization, settings: settings).call
    staff_by_id = result[:staff].index_by { |row| row[:tax_user_id] }

    expect(staff_by_id[101][:suggestion]).to eq(
      disposition: "employee",
      employee_id: unique_staff.id,
      label: "Benjo Cruz",
      match: "exact"
    )
    expect(staff_by_id[102][:suggestion]).to be_nil
    expect(staff_by_id[103][:suggestion]).to be_nil

    # Inactive-only email never gets an exact suggestion (falls back to similar or nil).
    expect(staff_by_id[104][:suggestion]&.dig(:match)).not_to eq("exact")

    # Active + terminated sharing an email matches the single active record by exact email.
    expect(staff_by_id[105][:suggestion]).to eq(
      disposition: "employee",
      employee_id: active_rehire.id,
      label: "Mark Active",
      match: "exact"
    )

    # Historical/inactive records remain available in the manual selection list.
    option_ids = result[:employees].map { |option| option[:id] }
    expect(option_ids).to include(inactive_only_staff.id, inactive_prior.id)
  end

  it "suggests no one from the local part of a rejected email, but keeps the name fallback for other addresses" do
    import = WorkHourImport.first
    create(:employee, company: practice_company, first_name: "Lina", last_name: "Family", email: "ana.family@example.com", status: "active")
    create(:employee, company: practice_company, first_name: "Joe", last_name: "Family", email: "ana.family@example.com", status: "active")
    [ [ 201, "ana.family@example.com" ], [ 202, "benjo.cruz@personal.example" ] ].each do |tax_user_id, email|
      WorkHourRow.create!(organization: organization, work_hour_import: import, tax_user_id: tax_user_id, email: email,
        client_name: "Client A", approval_state: "approved", work_date: Date.new(2026, 11, 11), hours: 1)
    end
    # Marking Benjo's real address as a placeholder must not fall back to "benjo".
    EmployeePlaceholderEmail.create!(organization: organization, email: "benjo@example.com")

    staff_by_id = described_class.new(organization: organization, settings: settings).call[:staff].index_by { |row| row[:tax_user_id] }

    expect(staff_by_id[101][:suggestion]).to be_nil
    # Two active employees share this address: no suggestion, even though only Ana Reyes is named Ana.
    expect(staff_by_id[201][:suggestion]).to be_nil
    # An address no employee uses still gets the name fallback.
    expect(staff_by_id[202][:suggestion]).to eq(disposition: "employee", employee_id: unique_staff.id, label: "Benjo Cruz", match: "similar")
  end

  it "loads organization marked placeholders at most once across all staff rows" do
    EmployeePlaceholderEmail.create!(organization: organization, email: "shared-office@example.com")
    expect(EmployeeContactValidator).to receive(:db_marked_placeholder_emails)
      .with(organization.id).once.and_call_original

    described_class.new(organization: organization, settings: settings).call
  end
end
