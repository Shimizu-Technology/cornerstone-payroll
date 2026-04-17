# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueCorrectivePaycheckService do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company, auto_create_fit_check: false) }
  let(:department) { create(:department, company: company) }
  let(:employee) do
    create(:employee, company: company, department: department,
                      pay_rate: 15.00, pay_frequency: "biweekly",
                      filing_status: "single", allowances: 0)
  end
  let(:original_period) do
    create(:pay_period, :committed, company: company,
                                    start_date: Date.new(2024, 1, 1),
                                    end_date:   Date.new(2024, 1, 14),
                                    pay_date:   Date.new(2024, 1, 19))
  end
  let!(:original_item) do
    item = original_period.payroll_items.build(
      employee:        employee,
      company_id:      company.id,
      employment_type: "hourly",
      pay_rate:        15.00,
      hours_worked:    60
    )
    PayrollCalculator.for(employee, item).calculate
    item.save!
    # Mirror what `commit` would have done so the YTD baseline is
    # consistent for the corrective recalculation.
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
                    .add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024)
                    .add_payroll_item!(item)
    company.assign_check_numbers!([item])
    item.reload
  end
  let(:actor) do
    User.create!(company: company, email: "actor@corrective.com",
                 name: "Corrective Actor", role: "admin", active: true)
  end

  describe ".preview" do
    it "returns deltas for an additional-hours correction without persisting" do
      expect {
        result = described_class.preview(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 } # +20h * $15
        )

        expect(result[:original][:gross_pay]).to be_within(0.01).of(900.00) # 60h * $15
        expect(result[:corrected][:gross_pay]).to be_within(0.01).of(1200.00) # 80h * $15
        expect(result[:deltas][:gross_pay]).to be_within(0.01).of(300.00)
        # SS = 6.2% of delta gross
        expect(result[:deltas][:social_security_tax]).to be_within(0.01).of(18.60)
        # Medicare = 1.45% of delta gross
        expect(result[:deltas][:medicare_tax]).to be_within(0.01).of(4.35)
        # Net delta = gross_delta - tax_deltas (positive → check will be cut)
        expect(result[:deltas][:net_pay]).to be > 0
        expect(result[:meta][:will_generate_check]).to eq(true)
        expect(result[:meta][:is_zero_change]).to eq(false)
      }.not_to change(PayPeriod, :count)
    end

    it "flags zero_change when the corrected inputs match the originals" do
      result = described_class.preview(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 60 }
      )
      expect(result[:meta][:is_zero_change]).to eq(true)
      expect(result[:deltas][:gross_pay]).to be_within(0.01).of(0.0)
    end

    it "raises if the employee has no item in the original period" do
      other_employee = create(:employee, company: company, department: department)
      expect {
        described_class.preview(original_pay_period: original_period,
                                employee: other_employee,
                                corrected_inputs: { hours_worked: 80 })
      }.to raise_error(IssueCorrectivePaycheckService::OriginalNotFoundError)
    end

    it "rejects contractor employees" do
      contractor = create(:employee, company: company, department: department,
                                     employment_type: "contractor")
      original_period.payroll_items.create!(
        employee: contractor, company_id: company.id,
        employment_type: "contractor", pay_rate: 50.00, hours_worked: 10,
        gross_pay: 500.00, net_pay: 500.00
      )
      expect {
        described_class.preview(original_pay_period: original_period,
                                employee: contractor,
                                corrected_inputs: { hours_worked: 12 })
      }.to raise_error(IssueCorrectivePaycheckService::UnsupportedEmployeeError)
    end
  end

  describe ".issue!" do
    it "creates a committed supplemental pay_period with one corrective item" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "Client reported 80h not 60h",
          actor:               actor
        )
      }.to change(PayPeriod, :count).by(1)
        .and change(PayrollItem, :count).by(1)

      supplemental = PayPeriod.last
      expect(supplemental).to be_supplemental
      expect(supplemental.corrects_pay_period_id).to eq(original_period.id)
      expect(supplemental).to be_committed
      expect(supplemental.pay_date).to eq(Date.new(2024, 1, 26))
      expect(supplemental.start_date).to eq(original_period.start_date)
      expect(supplemental.end_date).to eq(original_period.end_date)
      expect(supplemental.tax_sync_status).to eq("pending")

      corrective = supplemental.payroll_items.first
      expect(corrective.correction_for_payroll_item_id).to eq(original_item.id)
      expect(corrective.correction_reason).to eq("Client reported 80h not 60h")
      expect(corrective.gross_pay).to be_within(0.01).of(300.00)
      expect(corrective.net_pay).to be > 0
      expect(corrective.check_number).to be_present
    end

    it "updates Employee and Company YTD totals by the delta" do
      original_employee_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay
      original_company_ytd  = CompanyYtdTotal.find_by(company_id: company.id, year: 2024).gross_pay

      described_class.issue!(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80 },
        pay_date:            Date.new(2024, 1, 26),
        reason:              "+20h",
        actor:               actor
      )

      expect(EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay)
        .to be_within(0.01).of(original_employee_ytd + 300.00)
      expect(CompanyYtdTotal.find_by(company_id: company.id, year: 2024).gross_pay)
        .to be_within(0.01).of(original_company_ytd + 300.00)
    end

    it "the corrective period is reportable_committed (so it counts in YTD/W-2/reports)" do
      _, _ = described_class.issue!(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80 },
        pay_date:            Date.new(2024, 1, 26),
        reason:              "+20h",
        actor:               actor
      )

      supplemental = PayPeriod.supplemental_cycle.first
      expect(PayPeriod.reportable_committed.where(id: supplemental.id)).to exist
    end

    it "enqueues PayrollTaxSyncJob for the supplemental period" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "+20h",
          actor:               actor
        )
      }.to have_enqueued_job(PayrollTaxSyncJob)
    end

    it "auto-generates a FIT NonEmployeeCheck when the company opted in and there is positive FIT delta" do
      company.update!(auto_create_fit_check: true)

      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "+20h",
          actor:               actor
        )
      }.to change(NonEmployeeCheck, :count).by(1)

      supplemental = PayPeriod.supplemental_cycle.first
      fit_check = supplemental.non_employee_checks.first
      expect(fit_check.payable_to).to eq("Treasurer of Guam")
      expect(fit_check.auto_generated_type).to eq("fit_deposit")
    end

    it "raises if the original period is voided" do
      voided_period = create(:pay_period, :voided, company: company)
      original_period.payroll_items.first.update!(pay_period: voided_period)

      expect {
        described_class.issue!(
          original_pay_period: voided_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "should fail",
          actor:               actor
        )
      }.to raise_error(IssueCorrectivePaycheckService::CorrectionError)
    end

    it "raises when there is no actual change to the inputs" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 60 }, # same as original
          pay_date:            Date.new(2024, 1, 26),
          reason:              "no-op",
          actor:               actor
        )
      }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /do not change/)
    end

    it "permits multiple supplementals against the same source period" do
      described_class.issue!(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80 },
        pay_date:            Date.new(2024, 1, 26),
        reason:              "first correction",
        actor:               actor
      )

      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 65 },
          pay_date:            Date.new(2024, 2, 2),
          reason:              "second correction (still wrong)",
          actor:               actor
        )
      }.to change(PayPeriod, :count).by(1)

      expect(original_period.reload.supplemental_pay_periods.size).to eq(2)
    end
  end
end
