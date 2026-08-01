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
    company.assign_check_numbers!([ item ])
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

    it "rejects an original contractor item even if the employee is now W-2" do
      contractor = create(:employee, :contractor, company: company, department: department)
      original_period.payroll_items.create!(
        employee: contractor,
        company_id: company.id,
        employment_type: "contractor",
        pay_rate: 175.00,
        gross_pay: 175.00,
        net_pay: 175.00
      )
      contractor.allow_tax_classification_change = true
      contractor.update!(
        employment_type: "hourly",
        pay_rate: 15.00,
        hire_date: Date.new(2024, 1, 1),
        ssn_encrypted: "900-70-0099",
        address_line1: "123 Marine Corps Dr",
        city: "Hagatna",
        state: "GU",
        zip: "96910"
      )

      expect {
        described_class.preview(
          original_pay_period: original_period,
          employee: contractor,
          corrected_inputs: { hours_worked: 12 }
        )
      }.to raise_error(IssueCorrectivePaycheckService::UnsupportedEmployeeError)
    end

    it "uses the original W-2 classification when the employee's current type changed" do
      employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)

      _supplemental, corrective = described_class.issue!(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { hours_worked: 80 },
        pay_date: Date.new(2024, 1, 26),
        reason: "Correct historical hourly wages",
        actor: actor
      )

      expect(corrective.employment_type).to eq("hourly")
      expect(corrective.gross_pay).to be_within(0.01).of(300.00)
      expect(corrective.social_security_tax).to be_within(0.01).of(18.60)
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
      expect(supplemental.tax_sync_status).to be_nil

      corrective = supplemental.payroll_items.first
      expect(corrective.correction_for_payroll_item_id).to eq(original_item.id)
      expect(corrective.correction_reason).to eq("Client reported 80h not 60h")
      expect(corrective.gross_pay).to be_within(0.01).of(300.00)
      expect(corrective.net_pay).to be > 0
      expect(corrective.check_number).to be_present
    end

    it "stores reported-tip deltas on the corrective row for W-2GU and 941 reporting" do
      original_item.update_columns(
        reported_tips: 0.0,
        tips_paid_out: 50.0,
        total_deductions: original_item.total_deductions.to_f + 50.0,
        net_pay: original_item.net_pay.to_f - 50.0
      )

      supplemental, corrective = described_class.issue!(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { tips_paid_out: 50.0 },
        pay_date:            Date.new(2024, 1, 26),
        reason:              "Daily paid-out tips were not included in taxable tips",
        actor:               actor
      )

      expect(supplemental).to be_committed
      expect(corrective.reported_tips).to eq(50.0)
      expect(corrective.tips_paid_out).to eq(0.0)
      expect(corrective.gross_pay).to be_within(0.01).of(50.0)
      expect(corrective.net_pay).to be > 0
    end

    it "stores signed taxable-base deltas for legacy tipped-income corrections" do
      original_item.update!(
        hours_worked: 20,
        reported_tips: 200.0,
        tips_paid_out: 200.0
      )
      original_item.calculate!
      original_item.update_columns(
        fit_taxable_wages: nil,
        social_security_taxable_wages: nil,
        social_security_taxable_tips: nil,
        medicare_taxable_wages: nil,
        additional_medicare_taxable_wages: nil,
        additional_medicare_tax: nil,
        cash_tips_reported: nil
      )

      _, corrective = described_class.issue!(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { reported_tips: 0.0, tips_paid_out: 0.0 },
        pay_date: Date.new(2024, 1, 26),
        reason: "Remove tips reported on the original paycheck",
        actor: actor
      )

      expect(corrective.gross_pay).to eq(-200.0)
      expect(corrective.social_security_taxable_wages).to eq(0.0)
      expect(corrective.social_security_taxable_tips).to eq(-200.0)
      expect(corrective.medicare_taxable_wages).to eq(-200.0)
      expect(corrective.cash_tips_reported).to eq(-200.0)
      expect(corrective.tax_rule_snapshot).to be_present
    end

    it "allows a corrective paycheck to clear the supplemental row tip pool" do
      original_item.update_columns(tip_pool: "foh")

      _, corrective = described_class.issue!(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80, tip_pool: "" },
        pay_date:            Date.new(2024, 1, 26),
        reason:              "Corrected hours and removed tip pool assignment",
        actor:               actor
      )

      expect(corrective.tip_pool).to be_nil
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

    it "does not enqueue PayrollTaxSyncJob for the supplemental period when CST ingest is not configured" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "+20h",
          actor:               actor
        )
      }.not_to have_enqueued_job(PayrollTaxSyncJob)
    end

    it "enqueues PayrollTaxSyncJob for the supplemental period when CST ingest is configured" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CST_INGEST_URL").and_return("https://tax.example.test/ingest")

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

    # Regression for the stale-memoization race flagged by Greptile (P1).
    # `validate_for_issue!` (called outside the transaction) memoizes
    # `@original_item` and reads its `voided?` state. If a concurrent void
    # commits in the window between validation and the `FOR UPDATE` lock
    # acquisition, the in-transaction `assert_correctable!` was previously
    # checking the *stale* cached snapshot, so the guard silently passed
    # and a corrective paycheck was issued against a voided original —
    # corrupting the employee's YTD against a base the void had removed.
    it "re-reads the payroll item under lock so a concurrent void is caught" do
      service = described_class.new(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80 },
        pay_date:            Date.new(2024, 2, 1),
        reason:              "Concurrent-void race regression",
        actor:               actor
      )

      # Force memoization of `@original_item` (snapshot says voided=false).
      service.send(:original_item)
      expect(service.send(:original_item).voided?).to eq(false)

      # Simulate a concurrent void that commits *after* validation but
      # *before* (or as) the transaction lock is acquired. `update_columns`
      # mutates the DB row directly without touching our cached instance.
      original_item.update_columns(
        voided:    true,
        voided_at: Time.current,
        void_reason: "Concurrent void test"
      )

      expect {
        service.issue!
      }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /voided/)

      # Critical: no supplemental period should have been persisted, since
      # the lock-time re-read should have raised before any writes.
      expect(original_period.reload.supplemental_pay_periods.count).to eq(0)
    end

    # Regression for the temporal-validation gap flagged by Greptile (P1).
    # `reportable_committed` includes correction supplementals (so YTD-
    # aggregating reports stay correct). `ytd_sum_excluding_original`
    # filters by `pay_periods.pay_date < original.pay_date`. The
    # model-level `pay_date_after_end_date` validation only enforces
    # `pay_date >= end_date` — and because regular pay periods always
    # have a gap between `end_date` and `pay_date`, a supplemental's
    # `pay_date` can be "valid" by the model but still pre-date the
    # original's `pay_date`. If a first correction is committed with
    # such a backdated `pay_date` and a second correction is then
    # issued for the same original, the first correction's delta lands
    # inside `ytd_sum_excluding_original`'s window — inflating the
    # second's pre-period YTD basis and corrupting its SS/FIT math.
    # The service-level temporal guard closes that hole.
    it "rejects a supplemental pay_date that pre-dates the original period's pay_date" do
      # original_period: end_date 2024-01-14, pay_date 2024-01-19.
      # 2024-01-15 passes the model's `pay_date_after_end_date` validation
      # (>= end_date) but is BEFORE the original's pay_date — this is
      # exactly the gap the bug exploits.
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 15),
          reason:              "Backdated pay_date should be rejected",
          actor:               actor
        )
      }.to raise_error(ArgumentError, /on or after the original period's pay_date/)

      expect(original_period.reload.supplemental_pay_periods.count).to eq(0)
    end

    it "accepts a supplemental pay_date equal to the original's pay_date (boundary)" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            original_period.pay_date,
          reason:              "Same-day correction is allowed",
          actor:               actor
        )
      }.to change(PayPeriod, :count).by(1)
    end

    it "accepts an ISO-string pay_date (controllers send strings)" do
      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            "2024-01-26",
          reason:              "String-typed pay_date should still parse for validation",
          actor:               actor
        )
      }.to change(PayPeriod, :count).by(1)
    end

    it "raises cleanly when the original payroll item is deleted between validate and lock" do
      service = described_class.new(
        original_pay_period: original_period,
        employee:            employee,
        corrected_inputs:    { hours_worked: 80 },
        pay_date:            Date.new(2024, 2, 1),
        reason:              "Concurrent-delete race regression",
        actor:               actor
      )

      # Memoize, then destroy out of band before issue! re-reads.
      # `destroy` (rather than `delete`) handles dependent associations
      # like `payroll_item_earnings`.
      service.send(:original_item)
      original_item.destroy!

      expect {
        service.issue!
      }.to raise_error(IssueCorrectivePaycheckService::InvalidStateError,
                       /no longer exists/)
      expect(original_period.reload.supplemental_pay_periods.count).to eq(0)
    end
  end
end
