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

  let!(:unique_staff) { create(:employee, company: practice_company, first_name: "Benjo", last_name: "Cruz", email: "benjo@example.com") }
  let!(:shared_staff_a) { create(:employee, company: practice_company, first_name: "Ana", last_name: "Reyes", email: "shared-office@example.com") }
  let!(:shared_staff_b) { create(:employee, company: practice_company, first_name: "Carlos", last_name: "Santos", email: "shared-office@example.com") }
  let!(:placeholder_staff) { create(:employee, company: practice_company, first_name: "Maria", last_name: "Flores", email: "noemail@example.com") }

  before do
    import = WorkHourImport.create!(
      organization: organization,
      status: "succeeded",
      range_start: Date.new(2026, 11, 1),
      range_end: Date.new(2026, 11, 30)
    )
    WorkHourRow.create!(
      organization: organization,
      work_hour_import: import,
      tax_user_id: 101,
      email: "benjo@example.com",
      client_name: "Client A",
      approval_state: "approved",
      work_date: Date.new(2026, 11, 10),
      hours: 2.0
    )
    WorkHourRow.create!(
      organization: organization,
      work_hour_import: import,
      tax_user_id: 102,
      email: "shared-office@example.com",
      client_name: "Client A",
      approval_state: "approved",
      work_date: Date.new(2026, 11, 10),
      hours: 3.0
    )
    WorkHourRow.create!(
      organization: organization,
      work_hour_import: import,
      tax_user_id: 103,
      email: "noemail@example.com",
      client_name: "Client A",
      approval_state: "approved",
      work_date: Date.new(2026, 11, 10),
      hours: 1.5
    )
  end

  it "suggests an exact match for a unique real email and refuses exact matches for shared or placeholder emails" do
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
  end
end
