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
  let(:original_hours) { 60 }
  let!(:original_item) do
    item = original_period.payroll_items.build(
      employee:        employee,
      company_id:      company.id,
      employment_type: "hourly",
      pay_rate:        15.00,
      hours_worked:    original_hours
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

  describe "cumulative corrections" do
    def issue_target(inputs, pay_date: Date.new(2024, 1, 26))
      described_class.issue!(original_pay_period: original_period, employee: employee,
        corrected_inputs: inputs, pay_date: pay_date, reason: "Verified corrected target", actor: actor)
    end

    def expect_ytd_to_match_ledger(items)
      employee_ytd = employee.ytd_totals_for(2024).reload
      company_ytd = CompanyYtdTotal.find_by!(company_id: company.id, year: 2024)
      %i[gross_pay net_pay withholding_tax social_security_tax medicare_tax].each do |field|
        expected = items.sum { |item| item.public_send(field).to_d }
        expect(employee_ytd.public_send(field)).to eq(expected), "employee #{field}"
        expect(company_ytd.public_send(field)).to eq(expected), "company #{field}"
      end
      { employer_social_security: :employer_social_security_tax, employer_medicare: :employer_medicare_tax }.each do |field, item_field|
        expect(company_ytd.public_send(field)).to eq(items.sum { |item| item.public_send(item_field).to_d }), field.to_s
      end
    end

    shared_examples "a signed recorded baseline after a void" do
      it "repairs 10 to 20 to 1 after voiding the first delta without rewriting history or repeating YTD" do
        frozen_original = original_item.attributes.deep_dup
        frozen_earnings = original_item.payroll_item_earnings.map(&:attributes)
        first_period, = issue_target({ hours_worked: 20 })
        _, second = issue_target({ hours_worked: 1 })
        frozen_second = second.attributes.deep_dup
        before_void = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 2 })
        PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Reverse the first positive adjustment")
        expect_ytd_to_match_ledger([ original_item, second ])
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(-9 * original_item.pay_rate)
        ytd_before = employee.ytd_totals_for(2024).reload.attributes
        company_ytd_before = CompanyYtdTotal.find_by!(company_id: company.id, year: 2024).gross_pay

        expect {
          described_class.issue!(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 2 },
            expected_review_digest: before_void[:meta][:review_digest], pay_date: Date.new(2024, 1, 26), reason: "Stale review", actor: actor)
        }.to raise_error(described_class::StalePreviewError, /refresh|review/i)
        expect(employee.ytd_totals_for(2024).reload.attributes).to eq(ytd_before)
        expect(original_period.supplemental_pay_periods.count).to eq(2)

        preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 1 })
        expect(preview[:recorded]).to include(hours_worked: -9, gross_pay: -9 * original_item.pay_rate)
        expect(preview[:corrected]).to include(hours_worked: 1, gross_pay: original_item.pay_rate.to_f)
        expect(preview[:deltas]).to include(hours_worked_delta: 10, gross_pay: 10 * original_item.pay_rate)
        if original_item.wage_rate_hours.present?
          expect(preview[:recorded][:custom_columns_data].fetch("wage_rate_hours").sole.fetch("regular_hours")).to eq(-9)
          expect(preview[:corrected][:custom_columns_data].fetch("wage_rate_hours").sole.fetch("regular_hours")).to eq(1)
        end
        _, repair = described_class.issue!(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 1 },
          expected_review_digest: preview[:meta][:review_digest], pay_date: Date.new(2024, 1, 26), reason: "Repair the recorded balance", actor: actor)
        expect(repair.hours_worked).to eq(10)
        described_class::DELTA_OUTPUT_FIELDS.each do |field|
          total = original_item.public_send(field).to_d + second.public_send(field).to_d + repair.public_send(field).to_d
          expect(total).to eq(preview[:corrected][field].to_d.round(2)), field.to_s
        end
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(ytd_before.fetch("gross_pay") + repair.gross_pay)
        expect(CompanyYtdTotal.find_by!(company_id: company.id, year: 2024).gross_pay).to eq(company_ytd_before + repair.gross_pay)
        expect_ytd_to_match_ledger([ original_item, second, repair ])
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(original_item.pay_rate)
        expect(original_item.reload.attributes).to eq(frozen_original)
        expect(original_item.payroll_item_earnings.reload.map(&:attributes)).to eq(frozen_earnings)
        expect(second.reload.attributes).to eq(frozen_second)
        ytd_after = employee.ytd_totals_for(2024).reload.attributes
        expect {
          described_class.issue!(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 1 },
            expected_review_digest: preview[:meta][:review_digest], pay_date: Date.new(2024, 1, 26), reason: "Repeated repair", actor: actor)
        }.to raise_error(described_class::StalePreviewError)
        expect { issue_target({ hours_worked: 1 }) }.to raise_error(described_class::InvalidStateError, /already recorded/)
        expect(employee.ytd_totals_for(2024).reload.attributes).to eq(ytd_after)
        expect(original_period.supplemental_pay_periods.count).to eq(3)
      end

      it "restores exact YTD when the negative corrective is voided" do
        _, first = issue_target({ hours_worked: 20 })
        second_period, = issue_target({ hours_worked: 1 })
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(original_item.pay_rate)
        PayPeriodCorrectionService.void!(pay_period: second_period, actor: actor, reason: "Reverse the negative adjustment")
        expect_ytd_to_match_ledger([ original_item, first ])
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(20 * original_item.pay_rate)
      end

      it "still rejects a negative absolute target even when recorded hours are signed" do
        first_period, = issue_target({ hours_worked: 20 })
        issue_target({ hours_worked: 1 })
        PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Reverse first adjustment")
        ytd_before = employee.ytd_totals_for(2024).reload.attributes
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: -1 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /absolute hours must be nonnegative/)
        expect {
          issue_target({ hours_worked: -1 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /absolute hours must be nonnegative/)
        expect(original_period.supplemental_pay_periods.count).to eq(2)
        expect(employee.ytd_totals_for(2024).reload.attributes).to eq(ytd_before)
      end
    end

    context "with scalar hourly inputs and a signed recorded baseline" do
      let(:original_hours) { 10 }

      include_examples "a signed recorded baseline after a void"
    end

    it "posts only the remaining delta for 60 to 80 to 65 and preserves the frozen original" do
      frozen_original = original_item.attributes.deep_dup
      _, first = issue_target({ hours_worked: 80 })
      preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 65 })
      expect(preview[:original][:hours_worked]).to eq(60)
      expect(preview[:recorded][:hours_worked]).to eq(80)
      expect(preview[:recorded][:gross_pay]).to eq(1200)
      expect(preview[:deltas][:hours_worked_delta]).to eq(-15)
      _, second = issue_target({ hours_worked: 65 })
      expect(first.hours_worked).to eq(20)
      expect(second.hours_worked).to eq(-15)
      expect(second.gross_pay).to eq(-225)
      described_class::DELTA_OUTPUT_FIELDS.each do |field|
        total = original_item.public_send(field).to_d + first.public_send(field).to_d + second.public_send(field).to_d
        expect(total).to eq(preview[:corrected][field].to_d.round(2)), field.to_s
      end
      expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(975)
      expect(original_item.reload.attributes).to eq(frozen_original)
      expect(second.check_number).to be_nil
    end

    it "rechecks an identical absolute target under lock instead of duplicating money from a stale preview" do
      stale = described_class.new(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 80 },
        pay_date: Date.new(2024, 1, 26), reason: "Same target", actor: actor)
      stale.preview
      issue_target({ hours_worked: 80 })
      ytd = employee.ytd_totals_for(2024).reload.attributes
      expect { stale.issue! }.to raise_error(described_class::InvalidStateError, /already recorded|do not change/)
      expect(original_period.supplemental_pay_periods.count).to eq(1)
      expect(employee.ytd_totals_for(2024).reload.attributes).to eq(ytd)
    end

    it "keeps omitted corrected inputs at their effective values across later partial requests" do
      issue_target({ hours_worked: 80, bonus: 100, pay_rate: 20 })
      preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 65 })
      expect(preview[:corrected]).to include(hours_worked: 65, bonus: 100, pay_rate: 20, gross_pay: 1400)
      expect(preview[:deltas][:gross_pay]).to eq(-300)
    end

    it "excludes voided correctives from the recorded financial and input baseline" do
      first_period, = issue_target({ hours_worked: 80 })
      issue_target({ hours_worked: 65 })
      PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "First adjustment reversed")
      preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: {})
      expect(preview[:recorded][:hours_worked]).to eq(45)
      expect(preview[:recorded][:gross_pay]).to eq(675)
      expect(preview[:corrected][:hours_worked]).to eq(45)
      expect(preview[:deltas][:gross_pay]).to eq(0)
      expect(preview[:deltas][:net_pay]).to eq((preview[:corrected][:net_pay].to_d - preview[:recorded][:net_pay].to_d).round(2))
    end

    it "does not repeat a correction after the latest corrective is voided" do
      issue_target({ hours_worked: 80 })
      last_period, = issue_target({ hours_worked: 65 })
      PayPeriodCorrectionService.void!(pay_period: last_period, actor: actor, reason: "Last correction reversed")
      preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 80 })
      expect(preview[:recorded][:hours_worked]).to eq(80)
      expect(preview[:meta][:is_zero_change]).to eq(true)
    end

    [ {}, { "corrective_paycheck" => "invalid" } ].each do |invalid_snapshot|
      it "fails closed when legacy active corrections cannot establish omitted inputs (#{invalid_snapshot.inspect})" do
        _, first = issue_target({ hours_worked: 80 })
        first.update_columns(calculation_context_snapshot: invalid_snapshot)
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 65 })
        }.to raise_error(described_class::MissingHistoricalContextError, /prior correction.*input/i)
      end
    end

    it "uses the frozen historical tax basis while posting only the remaining delta in the correction pay year" do
      _, first = issue_target({ hours_worked: 80 }, pay_date: Date.new(2025, 1, 5))
      employee.update!(filing_status: "married", allowances: 5, pay_rate: 100)
      preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 65 })
      _, second = issue_target({ hours_worked: 65 }, pay_date: Date.new(2025, 1, 12))
      expect(second.gross_pay).to eq(-225)
      expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(900)
      expect(employee.ytd_totals_for(2025).reload.gross_pay).to eq(75)
      expect(original_item.social_security_tax + first.social_security_tax + second.social_security_tax)
        .to eq(preview[:corrected][:social_security_tax].to_d)
      expect(preview[:corrected][:pay_rate]).to eq(15)
    end

    it "rejects multi-rate originals instead of recalculating their categories as a scalar rate" do
      original_item.update_columns(custom_columns_data: { "wage_rate_hours" => [ { "rate" => 15, "regular_hours" => 40 }, { "rate" => 25, "regular_hours" => 20 } ] })
      expect {
        described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 65 })
      }.to raise_error(described_class::UnsupportedEmployeeError, /multi.rate/i)
    end

    context "with one verified hourly rate row" do
      let!(:historical_rate) { employee.employee_wage_rates.create!(label: "Flight Hours", rate: 25, active: true, is_primary: true) }
      let(:native_overtime) { 0 }
      let!(:original_item) do
        item = original_period.payroll_items.build(employee: employee, company_id: company.id,
          employment_type: "hourly", pay_rate: 25, hours_worked: 10, overtime_hours: native_overtime)
        item.wage_rate_hours = [ { employee_wage_rate_id: historical_rate.id, label: "Flight Hours", rate: 25,
          regular_hours: 10, overtime_hours: native_overtime, holiday_hours: 0, pto_hours: 0, active: true, is_primary: true } ]
        PayrollCalculator.for(employee, item).calculate
        item.save!
        employee.ytd_totals_for(2024).add_payroll_item!(item)
        CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024).add_payroll_item!(item)
        item.reload
      end

      include_examples "a signed recorded baseline after a void"

      it "uses the absolute target in a temporary sole row without changing the paid rate evidence" do
        frozen = original_item.attributes.deep_dup
        earnings = original_item.payroll_item_earnings.map(&:attributes)
        historical_rate.update!(rate: 50, label: "Current renamed rate", active: false)
        preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
        expect(preview[:corrected]).to include(hours_worked: 9, pay_rate: 25, gross_pay: 225)
        expect(preview[:deltas][:gross_pay]).to eq(-25)
        _, correction = described_class.issue!(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 },
          expected_review_digest: preview[:meta][:review_digest], pay_date: Date.new(2024, 1, 26), reason: "Correct one recorded day", actor: actor)
        expect(correction.gross_pay).to eq(-25)
        expect(correction.hours_worked).to eq(-1)
        expect(original_item.reload.attributes).to eq(frozen)
        expect(original_item.payroll_item_earnings.reload.map(&:attributes)).to eq(earnings)
      end

      it "composes successive target changes and zero-change detection using the same frozen rate" do
        _, first = issue_target({ hours_worked: 12 })
        preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
        expect(preview[:recorded]).to include(hours_worked: 12, gross_pay: 300)
        expect(preview[:deltas]).to include(gross_pay: -75, hours_worked_delta: -3)
        _, second = issue_target({ hours_worked: 9 })
        expect(first.gross_pay).to eq(50)
        expect(second.gross_pay).to eq(-75)
        expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(225)
        no_change = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: {})
        expect(no_change[:meta][:is_zero_change]).to eq(true)
        expect(no_change[:recorded][:custom_columns_data].fetch("wage_rate_hours").sole.fetch("regular_hours")).to eq(9)
        expect { issue_target({ hours_worked: 9 }) }.to raise_error(described_class::InvalidStateError, /already recorded/)
      end

      it "normalizes recorded row hours after an earlier correction is voided" do
        first_period, = issue_target({ hours_worked: 12 })
        issue_target({ hours_worked: 9 })
        PayPeriodCorrectionService.void!(pay_period: first_period, actor: actor, reason: "Reverse first adjustment")
        preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: {})
        expect(preview[:recorded][:hours_worked]).to eq(7)
        expect(preview[:recorded][:custom_columns_data].fetch("wage_rate_hours").sole.fetch("regular_hours")).to eq(7)
        expect(preview[:corrected]).to include(hours_worked: 7, gross_pay: 175)
      end

      [ -25, 30 ].each do |bad_rate|
        it "rejects a negative or mismatched historical snapshot rate #{bad_rate}" do
          columns = original_item.custom_columns_data.deep_dup
          columns.fetch("wage_rate_hours").sole["rate"] = bad_rate
          original_item.update_columns(custom_columns_data: columns)
          expect {
            described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
          }.to raise_error(described_class::UnsupportedEmployeeError, /rate|snapshot/i)
        end
      end

      it "rejects a row with missing native earning proof" do
        original_item.payroll_item_earnings.delete_all
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /evidence|snapshot/i)
      end

      it "rejects a rate snapshot owned by another employee" do
        other = create(:employee, company: company, department: department)
        foreign_rate = other.employee_wage_rates.create!(label: "Flight Hours", rate: 25, active: true)
        columns = original_item.custom_columns_data.deep_dup
        columns.fetch("wage_rate_hours").sole["employee_wage_rate_id"] = foreign_rate.id
        original_item.update_columns(custom_columns_data: columns)
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /snapshot/i)
      end

      it "rejects category snapshot hours that disagree with the native original inputs" do
        columns = original_item.custom_columns_data.deep_dup
        columns.fetch("wage_rate_hours").sole["regular_hours"] = 11
        original_item.update_columns(custom_columns_data: columns)
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /snapshot/i)
      end

      it "does not silently change the verified categorized rate through a scalar override" do
        expect {
          described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9, pay_rate: 30 })
        }.to raise_error(described_class::UnsupportedEmployeeError, /rate change/i)
      end

      context "with original overtime at the same frozen rate" do
        let(:native_overtime) { 2 }

        it "normalizes both absolute regular and overtime targets without altering the original components" do
          preview = described_class.preview(original_pay_period: original_period, employee: employee, corrected_inputs: { hours_worked: 9, overtime_hours: 1 })
          expect(preview[:original]).to include(hours_worked: 10, overtime_hours: 2, gross_pay: 325)
          expect(preview[:corrected]).to include(hours_worked: 9, overtime_hours: 1, gross_pay: 262.5)
          expect(preview[:deltas]).to include(hours_worked_delta: -1, overtime_hours_delta: -1, gross_pay: -62.5)
        end
      end
    end
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

    it "preserves and permits correction of a variable salary override" do
      salary_employee = create(
        :employee,
        :salary,
        company: company,
        department: department,
        salary_type: "variable",
        pay_rate: 0,
        pay_frequency: "biweekly"
      )
      salary_item = original_period.payroll_items.build(
        employee: salary_employee,
        company_id: company.id,
        employment_type: "salary",
        pay_rate: 0,
        salary_override: 2_000,
        hours_worked: 80
      )
      PayrollCalculator.for(salary_employee, salary_item).calculate
      salary_item.save!

      bonus_result = described_class.preview(
        original_pay_period: original_period,
        employee: salary_employee,
        corrected_inputs: { bonus: 100 }
      )
      override_result = described_class.preview(
        original_pay_period: original_period,
        employee: salary_employee,
        corrected_inputs: { salary_override: 2_500 }
      )

      expect(bonus_result[:original][:gross_pay]).to eq(2_000.0)
      expect(bonus_result[:corrected][:gross_pay]).to eq(2_100.0)
      expect(bonus_result[:deltas][:gross_pay]).to eq(100.0)
      expect(override_result[:corrected][:gross_pay]).to eq(2_500.0)
      expect(override_result[:deltas][:gross_pay]).to eq(500.0)
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

    it "recomputes exclusively from committed employee, deduction, field, and tax snapshots" do
      retirement_type = DeductionType.create!(
        company: company,
        name: "Historical insurance",
        category: "pre_tax",
        sub_category: "insurance"
      )
      employee.employee_deductions.create!(
        deduction_type: retirement_type,
        amount: 2.5,
        is_percentage: true
      )
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Historical benefit",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "benefit",
        amount_type: "percentage",
        default_percentage: 1.5,
        active: true
      )
      assignment = EmployeePayrollField.create!(
        employee: employee,
        payroll_field_definition: field,
        percentage: 1.5
      )
      employee.update!(
        retirement_rate: 0.03,
        roth_retirement_rate: 0.01,
        employer_retirement_match_rate: 0.02,
        employer_roth_match_rate: 0.005,
        additional_withholding: 7.5
      )

      verify_synthetic_retirement_plan!(employee, original_period.pay_date)

      original_item.destroy!
      refreshed_original = original_period.payroll_items.build(
        employee: employee,
        company_id: company.id,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 60
      )
      PayrollCalculator.for(employee, refreshed_original).calculate
      refreshed_original.save!
      EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
                      .update!(gross_pay: refreshed_original.gross_pay)
      company.assign_check_numbers!([ refreshed_original ])

      expected = described_class.preview(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { hours_worked: 80 }
      )

      employee.update!(
        pay_frequency: "monthly",
        filing_status: "married",
        allowances: 5,
        w4_step2_multiple_jobs: true,
        w4_dependent_credit: 2_000,
        w4_step4a_other_income: 12_000,
        w4_step4b_deductions: 4_000,
        additional_withholding: 100,
        retirement_rate: 0.10,
        roth_retirement_rate: 0.08,
        employer_retirement_match_rate: 0.09,
        employer_roth_match_rate: 0.07
      )
      employee.employee_deductions.find_by!(deduction_type: retirement_type).update!(amount: 25)
      assignment.update!(percentage: 20)
      field.update!(default_percentage: 30, active: false)
      tax_table.update!(ss_rate: 0.01, medicare_rate: 0.01)

      actual = described_class.preview(
        original_pay_period: original_period,
        employee: employee,
        corrected_inputs: { hours_worked: 80 }
      )

      expect(actual[:corrected]).to eq(expected[:corrected])
      expect(actual[:deltas]).to eq(expected[:deltas])
    end

    it "blocks legacy payroll rows that lack an immutable calculation context" do
      original_item.update_columns(calculation_context_snapshot: {})

      expect {
        described_class.preview(
          original_pay_period: original_period,
          employee: employee,
          corrected_inputs: { hours_worked: 80 }
        )
      }.to raise_error(
        IssueCorrectivePaycheckService::MissingHistoricalContextError,
        /cannot be safely recomputed/
      )
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
      expect(fit_check.payroll_liability_check_allocations.sum(:amount)).to eq(fit_check.amount)
    end

    it "reports a clean correction error and rolls back when the FIT payment cannot be connected" do
      company.update!(auto_create_fit_check: true)
      allow(PayrollLiabilityFitPaymentConnector).to receive(:connect!)
        .and_raise(PayrollLiabilityCheckAllocationService::Error, "selected liability is unavailable")
      period_count = PayPeriod.count
      payment_count = NonEmployeeCheck.count

      expect {
        described_class.issue!(
          original_pay_period: original_period,
          employee:            employee,
          corrected_inputs:    { hours_worked: 80 },
          pay_date:            Date.new(2024, 1, 26),
          reason:              "missed hours",
          actor:               actor
        )
      }.to raise_error(IssueCorrectivePaycheckService::CorrectionError,
                       /FIT payment could not be connected.*selected liability is unavailable/)
      expect(PayPeriod.count).to eq(period_count)
      expect(NonEmployeeCheck.count).to eq(payment_count)
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
