# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollExpectedEntries do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, :calculated, company: company, start_date: "2024-06-01", end_date: "2024-06-14", pay_date: "2024-06-19") }
  let(:employee) { create(:employee, company: company) }
  let(:rate) { create(:employee_wage_rate, employee: employee, rate: 20) }
  let(:field) { PayrollStandingChange.create!(company: company, employee: employee, employee_wage_rate: rate, kind: "extra_hours", label: "Manual hours", required: true) }
  before { ensure_verified_test_tax_years(2024) }

  def data
    described_class.new(period).payload
  end

  it "projects missing, audited none, and actual payroll hours in that order" do
    field
    expect(data[:outstanding]).to eq([ "Manual hours" ])
    resolution = PayrollEntryResolution.create!(pay_period: period, employee: employee, payroll_standing_change: field, note: "On leave")
    expect(data[:fields].sole).to include(status: "none", note: "On leave")
    expect(AuditLog.where(action: "payroll_entry_resolutions#save", record_id: period.id)).to exist
    create(:payroll_item, pay_period: period, employee: employee, hours_worked: 12, wage_rate_hours: [ { employee_wage_rate_id: rate.id, rate: 20, regular_hours: 12 } ])
    expect(data[:fields].sole).to include(status: "filled", value: "12.0")
    resolution.destroy!
    expect(data[:outstanding]).to be_empty
  end

  it "blocks approval and commit with exactly the outstanding label" do
    field
    service = PayPeriodLifecycleService.new(pay_period: period, actor: nil)
    expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Manual hours/)
    period.update!(status: "approved")
    expect { service.commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Manual hours/)
  end

  it "does not accept none when disallowed, but optional missing fields do not block" do
    field.update!(allow_none: false, required: false)
    expect(PayrollEntryResolution.new(pay_period: period, employee: employee, payroll_standing_change: field)).not_to be_valid
    expect(data[:outstanding]).to be_empty
  end

  it "does not count another job's hours" do
    field
    other = create(:employee_wage_rate, employee: employee, label: "Other", rate: 30)
    create(:payroll_item, pay_period: period, employee: employee, hours_worked: 12, wage_rate_hours: [ { employee_wage_rate_id: other.id, rate: 30, regular_hours: 12 } ])
    expect(data[:fields].sole[:status]).to eq("missing")
  end

  it "reports changed pay setup as needing attention and still permits deactivation" do
    field
    employee.update!(status: "terminated")
    expect(data[:fields].sole[:availability_error]).to include("terminated")
    expect(data[:outstanding]).to be_empty
    expect(field.update(active: false)).to be(true)
  end

  it "requires explicit owner period pay rather than a bonus" do
    owner = create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0)
    PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay", label: "Owner pay", required: true)
    item = create(:payroll_item, :salary, pay_period: period, employee: owner, bonus: 100, salary_override: nil)
    expect(data[:outstanding]).to eq([ "Owner pay" ])
    item.update!(salary_override: 900)
    expect(data[:fields].sole).to include(status: "filled", value: "900.0")
  end

  it "resolves a required field with a staff or portal exclusion even when none is disallowed" do
    field.update!(allow_none: false)
    period.pay_period_excluded_employees.create!(employee: employee, reason: "Client confirmed no pay")
    expect(data[:fields].sole).to include(status: "excluded", note: "Client confirmed no pay")
    expect(data[:outstanding]).to be_empty
  end

  it "blocks inline hours writes when legacy multi-job hours cannot be attributed safely" do
    field
    create(:employee_wage_rate, employee: employee, label: "Other", rate: 30)
    create(:payroll_item, pay_period: period, employee: employee, hours_worked: 12, wage_rate_hours: [])
    expect(data[:fields].sole[:inline_save_error]).to include("Assign them in the worksheet")
  end

  it "keeps deactivated jobs and changed salary setup visible without blocking" do
    field
    change_wage_rate!(rate, active: false)
    expect(data[:fields].sole[:availability_error]).to be_present
    expect(data[:outstanding]).to be_empty
    owner = create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0)
    PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay", required: true)
    change_compensation!(owner, salary_type: "per_period", pay_rate: 1000)
    expect(data[:fields].last[:availability_error]).to be_present
    expect(data[:outstanding]).to be_empty
  end

  context "recent regulars" do
    before do
      4.times do |index|
        past = create(:pay_period, company: company, start_date: Date.new(2024, 1, 1) + index * 14,
          end_date: Date.new(2024, 1, 14) + index * 14, pay_date: Date.new(2024, 1, 19) + index * 14)
        create(:payroll_item, pay_period: past, employee: employee, gross_pay: 200) if index < 3
        past.update!(status: "committed", committed_at: Time.current)
      end
    end

    it "detects 3 of 4, resolves with audit, and does not warn for a new hire or terminated worker" do
      create(:employee, company: company)
      expect(data[:missing_regulars].pluck(:employee_id)).to eq([ employee.id ])
      PayrollEntryResolution.create!(pay_period: period, employee: employee, note: "Unpaid leave")
      expect(data[:missing_regulars].sole[:resolved]).to be(true)
      expect(data[:outstanding]).to be_empty
      employee.update!(status: "terminated")
      expect(data[:missing_regulars]).to be_empty
    end

    it "blocks approval for an unresolved regular and accepts an audited resolution" do
      other = create(:employee, company: company)
      create(:payroll_item, pay_period: period, employee: other, gross_pay: 100)
      service = PayPeriodLifecycleService.new(pay_period: period, actor: nil)
      expect { service.approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /#{Regexp.escape(employee.full_name)}/)
      PayrollEntryResolution.create!(pay_period: period, employee: employee, note: "No work this period")
      expect { service.approve! }.not_to raise_error
      expect(period.reload).to be_approved
    end

    it "resolves missing regulars with the exclusion reason" do
      period.pay_period_excluded_employees.create!(employee: employee, reason: "No pay this period")
      expect(data[:missing_regulars].sole).to include(resolved: true, excluded: true, note: "No pay this period")
      expect(data[:outstanding]).to be_empty
    end

    it "still flags an active regular whose configured field became unavailable" do
      field
      change_wage_rate!(rate, active: false)
      expect(data[:fields].sole[:availability_error]).to be_present
      expect(data[:missing_regulars].pluck(:employee_id)).to eq([ employee.id ])
      expect(data[:outstanding]).to eq([ employee.full_name ])
    end

    %i[reported_tips service_charge_wages bonus].each do |earning|
      it "counts a reportable #{earning}-only item as covered" do
        create(:payroll_item, pay_period: period, employee: employee, gross_pay: 0, hours_worked: 0, earning => 50)
        expect(data[:missing_regulars]).to be_empty
      end
    end

    it "keeps a worker added back with import amounts missing until hours are entered" do
      item = create(:payroll_item, pay_period: period, employee: employee, employment_type: "hourly", gross_pay: 50, hours_worked: 0,
        reported_tips: 50, loan_deduction: 159.10, custom_columns_data: { "import_add_back" => { "import_id" => 1 } })
      expect(data[:missing_regulars].sole).to include(employee_id: employee.id, resolved: false, awaiting_hours: true)
      expect(data[:outstanding]).to eq([ employee.full_name ])
      item.update!(hours_worked: 40)
      expect(data[:missing_regulars]).to be_empty
    end

    it "lets staff confirm an added-back worker has no hours when tips are their only pay" do
      create(:payroll_item, pay_period: period, employee: employee, employment_type: "hourly", gross_pay: 50, hours_worked: 0,
        reported_tips: 50, custom_columns_data: { "import_add_back" => { "import_id" => 1 } })
      AuditLog.create!(actor_type: "system_job", actor_name: "System", company_id: company.id, action: "pay_period_excluded_employees#destroy", record_type: "PayPeriod", record_id: period.id,
        subject_name: employee.full_name, metadata: { employee_id: employee.id, restored_import_amounts: [ { kind: "tips", label: "Tips", amount: "50.0" } ],
          not_restored_import_amounts: [] })
      expect(data[:added_back]).to contain_exactly(include(employee_id: employee.id, hours_entered: false, no_hours: false))
      PayrollEntryResolution.create!(pay_period: period, employee: employee, note: "Tips only this period")
      expect(data[:missing_regulars].sole).to include(resolved: true, awaiting_hours: true, note: "Tips only this period")
      expect(data[:outstanding]).to be_empty
      # Answered, and nothing left to enter: the add-back notice is done.
      expect(data[:added_back]).to be_empty
    end

    it "honors threshold edges, excludes configured people, and clears when pay is entered" do
      company.update!(regular_pay_threshold: 4)
      expect(data[:missing_regulars]).to be_empty
      company.update!(regular_pay_threshold: 3)
      field
      expect(data[:missing_regulars]).to be_empty
      field.update!(active: false)
      create(:payroll_item, pay_period: period, employee: employee, gross_pay: 100)
      expect(data[:missing_regulars]).to be_empty
    end
  end
end
