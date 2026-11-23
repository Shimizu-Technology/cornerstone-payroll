# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayrollImport::ImportService do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, company: company, start_date: "2026-10-19", end_date: "2026-11-01", pay_date: "2026-11-05") }
  let!(:employee) { create(:employee, company: company, first_name: "Alex", last_name: "Example", pay_rate: 15.50) }
  let(:service) { described_class.new(period) }

  before do
    config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
    create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
  end

  def preview(hours: true, loan: 89)
    service.preview(
      pdf_records: hours ? [ { employee_name: "Example, Alex", regular_hours: 40, overtime_hours: 2, total_hours: 42 } ] : [],
      excel_records: [ { first_name: "Alex", last_name: "Example", loan_deduction: loan, recurring_loan_deduction: loan, total_tips: 0 } ]
    ).fetch(:matched).first
  end

  def import(row, **options)
    result = service.apply!(matched: [ row ], **options)
    expect(result[:errors]).to be_empty
    period.payroll_items.find_by!(employee: employee)
  end

  it "retains workbook loans through zero-pay calculation and restores them after emailed hours" do
    row = preview(hours: false)
    expect(row).to include(workbook_only: true, missing_revel_hours_with_deductions: true)
    item = import(row)
    expect(item.loan_deduction).to eq(0)
    expect(item.requested_loan_deduction).to eq(89)
    expect(period.reload.compliance_warnings.join).to include("No Revel hours", "$89.00 could not be deducted")
    item.hours_worked = 26
    item.calculate!
    expect(item.reload.loan_deduction).to eq(89)
    expect(item.requested_loan_deduction).to eq(89)
    expect(item.net_pay).to be_positive
    expect(item.deduction_review_warnings).to be_empty
  end

  it "caps a request larger than pay after hours, then restores it when pay increases" do
    item = import(preview(hours: false, loan: 500))
    item.hours_worked = 1
    item.calculate!
    expect(item.reload.loan_deduction).to be_between(0, 15.50).exclusive
    partial = item.loan_deduction
    expect(item.requested_loan_deduction).to eq(500)
    expect(item.net_pay).to eq(0)
    expect(item.deduction_review_warnings.join).to include("Loan requested $500.00; collected")
    item.calculate!
    expect(item.reload.loan_deduction).to eq(partial)
    item.hours_worked = 80
    item.calculate!
    expect(item.reload.loan_deduction).to eq(500)
    expect(item.net_pay).to be_positive
  end

  it "also retains, replaces and clears a manually entered loan request" do
    item = create(:payroll_item, pay_period: period, employee: employee, pay_rate: 15.50, hours_worked: 0, loan_deduction: 100)
    item.calculate!
    expect(item.reload.requested_loan_deduction).to eq(100)
    item.hours_worked = 40
    item.loan_deduction = 60
    item.calculate!
    expect(item.reload.loan_deduction).to eq(60)
    item.loan_deduction = 0
    item.calculate!
    expect(item.reload.requested_loan_deduction).to eq(0)
    expect(item.loan_payment).to eq(0)
  end

  it "retains requests on legacy rows with no request metadata" do
    item = create(:payroll_item, pay_period: period, employee: employee, hours_worked: 0)
    item.update_columns(loan_deduction: 89, custom_columns_data: {})
    item.reload.calculate!
    expect(item.reload.requested_loan_deduction).to eq(89)
    item.hours_worked = 40
    item.calculate!
    expect(item.reload.loan_deduction).to eq(89)
  end

  it "keeps entered hours on forced workbook-only overwrite and repeated import" do
    item = create(:payroll_item, pay_period: period, employee: employee, hours_worked: 26, overtime_hours: 3)
    row = preview(hours: false)
    import(row, force_overwrite: true)
    expect(item.reload.hours_worked).to eq(26)
    expect(item.overtime_hours).to eq(3)
    import(row)
    expect(item.reload.hours_worked).to eq(26)
    expect(item.loan_deduction).to eq(89)
  end

  it "flags configured loans on workbook-only rows even when capping removes their deductions" do
    type = DeductionType.create!(company: company, name: "Synthetic loan", category: "post_tax", sub_category: "loan")
    employee.employee_deductions.create!(deduction_type: type, amount: 50)
    EmployeeLoan.create!(company: company, employee: employee, deduction_type: type,
      name: "Synthetic scheduled loan", tracking_mode: "recurring_no_balance", payment_amount: 50, status: "active", first_deduction_date: period.pay_date)
    row = preview(hours: false, loan: 0)
    expect(row[:missing_revel_hours_with_deductions]).to be(true)
    item = import(row)
    expect(item.payroll_item_deductions).to be_empty
    expect(item.deduction_review_warnings.join).to include("No Revel hours")
  end

  it "flags a small percentage loan field on a workbook-only row" do
    field = create(:payroll_field_definition, company: company, kind: "deduction", category: "loan",
      tax_treatment: "post_tax_deduction", amount_type: "percentage")
    employee.employee_payroll_fields.create!(payroll_field_definition: field, percentage: 0.25)
    expect(preview(hours: false, loan: 0)[:missing_revel_hours_with_deductions]).to be(true)
  end

  context "with distinct active wage rates" do
    let!(:primary) { create(:employee_wage_rate, employee: employee, label: "Main Kitchen", rate: 15.50, is_primary: true) }
    let!(:joint) { create(:employee_wage_rate, employee: employee, label: "Shared Kitchen", rate: 16.50) }

    def committed_allocation(entries)
      previous = create(:pay_period, company: company, start_date: "2026-10-05", end_date: "2026-10-18", pay_date: "2026-10-22")
      item = create(:payroll_item, pay_period: previous, employee: employee, pay_rate: employee.pay_rate, gross_pay: 500)
      item.wage_rate_hours = entries
      item.calculate!
      previous.update_columns(status: "committed", committed_at: 1.day.ago)
      previous
    end

    def bucket(rate, hours = 30)
      { employee_wage_rate_id: rate.id, label: rate.label, rate: rate.rate, regular_hours: hours }
    end

    it "defaults to the latest earlier committed allocation and builds imported hours" do
      previous = committed_allocation([ bucket(joint) ])
      row = preview
      expect(row).to include(selected_wage_rate_id: joint.id, wage_rate_default_pay_period_id: previous.id)
      expect(row[:wage_rate_default_source]).to include("2026-10-22")
      item = import(row)
      expect(item.wage_rate_hours).to contain_exactly(include("employee_wage_rate_id" => joint.id, "rate" => 16.50, "regular_hours" => 40.0, "overtime_hours" => 2.0))
      expect(item.payroll_item_earnings.find_by!(category: "regular").amount).to eq(660)
      expect(item.payroll_item_earnings.find_by!(category: "overtime").amount).to eq(49.50)
    end

    it "requires a choice without history and rejects another employee's rate" do
      row = preview
      expect(row[:selected_wage_rate_id]).to be_nil
      expect(service.apply!(matched: [ row ])[:errors].first[:error]).to include("Choose an active job")
      stranger = create(:employee_wage_rate)
      expect(service.apply!(matched: [ row.merge(selected_wage_rate_id: stranger.id) ])[:errors]).to be_present
    end

    it "rejects a rate changed or deactivated since preview without changing existing hours" do
      row = preview.merge(selected_wage_rate_id: joint.id)
      change_wage_rate!(joint, rate: 18)
      result = service.apply!(matched: [ row ])
      expect(result[:errors].first[:error]).to include("rates changed")
      expect(period.payroll_items).to be_empty
      change_wage_rate!(joint, active: false)
      expect(service.apply!(matched: [ row ])[:errors].first[:error]).to include("Choose an active job")
    end

    it "uses an identifiable implicit single-rate allocation in legacy committed history" do
      previous = committed_allocation([])
      row = preview
      expect(row).to include(selected_wage_rate_id: primary.id, wage_rate_default_pay_period_id: previous.id)
    end

    it "keeps emailed scalar edits in the reviewed job, including a saved API-style update" do
      item = import(preview(hours: false).merge(selected_wage_rate_id: joint.id))
      item.update!(hours_worked: 26)
      item.reload.calculate!
      expect(item.reload.hours_worked).to eq(26)
      expect(item.wage_rate_hours.first).to include("regular_hours" => 26, "employee_wage_rate_id" => joint.id)
      expect(item.loan_deduction).to eq(89)
      item.hours_worked = 30
      item.calculate!
      expect(item.reload.hours_worked).to eq(30)
      expect(item.payroll_item_earnings.find_by!(category: "regular").amount).to eq(495)
    end

    it "counts negative-hour jobs and keeps same-job reversals identifiable" do
      previous = committed_allocation([ bucket(primary, 10) ])
      item = previous.payroll_items.find_by!(employee: employee)
      # Negative source reversals are retained as committed history, not fresh
      # nonnegative worksheet inputs. Only the default-selection reader runs.
      item.update_columns(custom_columns_data: { "wage_rate_hours" => [ bucket(primary, 10), bucket(joint, -2) ] })
      expect(preview[:selected_wage_rate_id]).to be_nil
      item.update_columns(custom_columns_data: { "wage_rate_hours" => [ bucket(joint, -2), bucket(joint, 10) ] })
      expect(preview[:selected_wage_rate_id]).to eq(joint.id)
    end

    it "requires a choice for a prior split instead of guessing" do
      committed_allocation([ bucket(primary, 10), bucket(joint, 20) ])
      row = preview
      expect(row[:selected_wage_rate_id]).to be_nil
      expect(import(row.merge(selected_wage_rate_id: joint.id)).wage_rate_hours.first["rate"]).to eq(16.50)
    end

    it "uses the review choice and replaces stale allocations on force overwrite" do
      committed_allocation([ bucket(joint) ])
      item = create(:payroll_item, pay_period: period, employee: employee, hours_worked: 90)
      item.wage_rate_hours = [ bucket(joint, 90) ]
      item.save!
      import(preview.merge(selected_wage_rate_id: primary.id), force_overwrite: true)
      expect(item.reload.wage_rate_hours).to contain_exactly(include("employee_wage_rate_id" => primary.id, "regular_hours" => 40.0))
      expect(item.hours_worked).to eq(40)
      expect(item.payroll_item_earnings.find_by!(category: "regular").amount).to eq(620)
    end

    it "keeps staff hours and rebuilds the reviewed job on a workbook-only force overwrite" do
      item = create(:payroll_item, pay_period: period, employee: employee, hours_worked: 26)
      item.wage_rate_hours = [ bucket(primary, 26) ]
      item.save!
      import(preview(hours: false).merge(selected_wage_rate_id: joint.id), force_overwrite: true)
      expect(item.reload.wage_rate_hours.first).to include("regular_hours" => 26, "employee_wage_rate_id" => joint.id, "rate" => 16.50)
      expect(item.payroll_item_earnings.find_by!(category: "regular").amount).to eq(429)
      expect(item.hours_worked).to eq(26)
      expect(item.loan_deduction).to eq(89)
    end
  end

  # MoSa: "Hourly rate" plus a department job, all at the same rate. Reports
  # show earnings by job label, so the department job must carry the hours.
  context "with equal-rate department jobs" do
    let!(:primary) { create(:employee_wage_rate, employee: employee, label: "Hourly rate", rate: 15.50, is_primary: true) }
    let!(:kitchen) { create(:employee_wage_rate, employee: employee, label: "Joint Kitchen", rate: 15.50) }
    let!(:vacation) { create(:employee_wage_rate, employee: employee, label: "Vacation", rate: 15.50) }

    def committed_allocation(entries)
      previous = create(:pay_period, company: company, start_date: "2026-10-05", end_date: "2026-10-18", pay_date: "2026-10-22")
      item = create(:payroll_item, pay_period: previous, employee: employee, pay_rate: employee.pay_rate, gross_pay: 500)
      item.wage_rate_hours = entries
      item.calculate!
      previous.update_columns(status: "committed", committed_at: 1.day.ago)
      previous
    end

    def bucket(rate, hours = 30)
      { employee_wage_rate_id: rate.id, label: rate.label, rate: rate.rate, regular_hours: hours }
    end

    it "puts the hours on the department job from the last committed payroll, without changing pay" do
      previous = committed_allocation([ bucket(kitchen) ])
      row = preview
      expect(row).to include(selected_wage_rate_id: kitchen.id, wage_rate_default_pay_period_id: previous.id, wage_rate_needs_review: false)
      expect(row[:wage_rate_options].map { |option| option[:label] }).to eq([ "Hourly rate", "Joint Kitchen", "Vacation" ])

      item = import(row)
      expect(item.wage_rate_hours).to contain_exactly(include("employee_wage_rate_id" => kitchen.id, "label" => "Joint Kitchen", "regular_hours" => 40.0, "overtime_hours" => 2.0))
      expect(item.payroll_item_earnings.map { |earning| [ earning.label, earning.amount ] }).to include([ "Joint Kitchen", 620 ], [ "Joint Kitchen OT", 46.50 ])
      # The same 40 + 2 hours at the profile rate, as an import without jobs paid them.
      expect(item.gross_pay).to eq(666.50)
      expect(item.custom_columns_data.dig("mosa_wage_rate_choice", "primary_job_fallback")).to be(false)

      summary = PDF::Reader.new(StringIO.new(PayrollSummaryByEmployeePdfGenerator.new(period).generate)).pages.map(&:text).join(" ")
      expect(summary).to include("Joint Kitchen")
    end

    it "keeps the primary job when that is what the last committed payroll used" do
      committed_allocation([ bucket(primary) ])
      expect(preview).to include(selected_wage_rate_id: primary.id, wage_rate_needs_review: false)
    end

    it "falls back to the primary job with a notice when there is no history, and applies without a choice" do
      row = preview
      expect(row).to include(selected_wage_rate_id: primary.id, wage_rate_needs_review: true, wage_rate_default_pay_period_id: nil)
      expect(row[:wage_rate_default_source]).to start_with("Primary job (Hourly rate). The last committed payroll doesn't show one job.")
      item = import(row)
      expect(item.wage_rate_hours.sole).to include("label" => "Hourly rate", "regular_hours" => 40.0)
      expect(item.gross_pay).to eq(666.50)
      expect(item.custom_columns_data.dig("mosa_wage_rate_choice", "primary_job_fallback")).to be(true)
    end

    it "never infers a split: a split last payroll falls back to the primary job with a notice" do
      committed_allocation([ bucket(primary, 10), bucket(kitchen, 20) ])
      row = preview
      expect(row).to include(selected_wage_rate_id: primary.id, wage_rate_needs_review: true)
      expect(row[:wage_rate_default_source]).to include("split hours across jobs")
      expect(import(row.merge(selected_wage_rate_id: kitchen.id)).wage_rate_hours.sole).to include("label" => "Joint Kitchen", "regular_hours" => 40.0)
    end

    it "keeps the profile-rate path when the profile rate differs from the jobs, so pay cannot change" do
      change_compensation!(employee, pay_rate: 16.00)
      row = preview
      expect(row).not_to have_key(:wage_rate_options)
      expect(import(row).wage_rate_hours).to be_empty
    end
  end

  it "keeps single-rate calculations unchanged and clears stale allocations" do
    create(:employee_wage_rate, employee: employee, rate: 15.50)
    row = preview
    expect(row[:wage_rate_options]).to be_nil
    item = create(:payroll_item, pay_period: period, employee: employee, import_source: "mosa_revel")
    item.wage_rate_hours = [ { label: "Old job", rate: 99, regular_hours: 90 } ]
    item.save!
    import(row)
    expect(item.reload.wage_rate_hours).to be_empty
    expect(item.payroll_item_earnings.find_by!(category: "regular").amount).to eq(620)
    expect(item.hours_worked).to eq(40)
  end
end
