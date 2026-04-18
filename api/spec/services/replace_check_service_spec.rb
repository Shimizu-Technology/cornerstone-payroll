# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReplaceCheckService do
  let!(:tax_table) { create(:tax_table) }
  let(:company)    { create(:company, auto_create_fit_check: false, next_check_number: 1001) }
  let(:department) { create(:department, company: company) }
  let(:employee) do
    create(:employee, company: company, department: department,
                      pay_rate: 15.00, pay_frequency: "biweekly",
                      filing_status: "single", allowances: 0)
  end
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
                                    start_date: Date.new(2024, 1, 1),
                                    end_date:   Date.new(2024, 1, 14),
                                    pay_date:   Date.new(2024, 1, 19))
  end
  # Build the committed item the way `commit` would: calculate, save, push to
  # YTD, assign a check number. This mirrors a real committed period so the
  # service exercises subtract→recompute→add cleanly.
  let!(:original_item) do
    item = pay_period.payroll_items.build(
      employee:        employee,
      company_id:      company.id,
      employment_type: "hourly",
      pay_rate:        15.00,
      hours_worked:    60
    )
    PayrollCalculator.for(employee, item).calculate
    item.save!
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
                    .add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024)
                   .add_payroll_item!(item)
    company.assign_check_numbers!([item])
    item.reload
  end
  let(:actor) do
    User.create!(company: company, email: "actor@replace.com",
                 name: "Replace Actor", role: "admin", active: true)
  end

  describe ".preview" do
    it "returns a delta snapshot in :in_place mode for an unprinted item" do
      result = described_class.preview(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 }
      )

      expect(result[:mode]).to eq(:in_place)
      expect(result[:original][:gross_pay]).to be_within(0.01).of(900.00)
      expect(result[:corrected][:gross_pay]).to be_within(0.01).of(1200.00)
      expect(result[:meta][:will_assign_new_check_number]).to eq(false)
      expect(result[:meta][:original_check_number]).to eq(original_item.check_number)
      expect(result[:meta][:is_zero_change]).to eq(false)
    end

    it "returns :void_and_reissue mode when the item was already printed" do
      original_item.update!(check_printed_at: Time.current, check_print_count: 1)

      result = described_class.preview(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 50 }
      )

      expect(result[:mode]).to eq(:void_and_reissue)
      expect(result[:meta][:will_assign_new_check_number]).to eq(true)
      expect(result[:corrected][:gross_pay]).to be_within(0.01).of(750.00)
    end

    it "flags zero_change when the corrected inputs match the originals" do
      result = described_class.preview(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 60 }
      )
      expect(result[:meta][:is_zero_change]).to eq(true)
    end

    it "rejects contractor checks" do
      contractor = create(:employee, company: company, department: department,
                                     employment_type: "contractor")
      contractor_item = pay_period.payroll_items.create!(
        employee: contractor, company_id: company.id,
        employment_type: "contractor", pay_rate: 50.00, hours_worked: 10,
        gross_pay: 500.00, net_pay: 500.00
      )
      expect {
        described_class.preview(payroll_item: contractor_item, corrected_inputs: { hours_worked: 12 })
      }.to raise_error(ReplaceCheckService::UnsupportedEmployeeError)
    end
  end

  describe ".replace! — :in_place mode (unprinted)" do
    it "rewrites the item with corrected values, keeps the same check #, and logs a replaced event" do
      original_check_number = original_item.check_number
      original_gross_ytd    = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay

      described_class.replace!(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 },
        reason:          "Client reported 80h not 60h",
        actor:           actor
      )

      reloaded = original_item.reload
      expect(reloaded.gross_pay).to be_within(0.01).of(1200.00)
      expect(reloaded.check_number).to eq(original_check_number)        # same #
      expect(reloaded.replaced_check_number).to be_nil                  # no void+reissue
      expect(reloaded.voided?).to eq(false)
      expect(reloaded.check_printed_at).to be_nil                       # ready for print

      # Audit: one `replaced` event, no `voided` event in :in_place mode.
      events = reloaded.check_events.reload.order(:created_at)
      expect(events.count).to eq(1)
      expect(events.first.event_type).to eq("replaced")
      expect(events.first.reason).to include("hours 60.0→80.0")

      # YTD: increased by the gross delta (300).
      new_gross_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay
      expect(new_gross_ytd).to be_within(0.01).of(original_gross_ytd + 300.00)
    end
  end

  describe ".replace! — :void_and_reissue mode (printed)" do
    before { original_item.update!(check_printed_at: Time.current, check_print_count: 1) }

    it "voids the original check #, assigns a new one, and updates YTD by the delta" do
      original_check_number = original_item.check_number
      next_check_number     = company.next_check_number

      result = described_class.replace!(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 },
        reason:          "Returned uncashed; corrected hours",
        actor:           actor
      )

      expect(result.check_number).to eq(next_check_number.to_s)
      expect(result.check_number).not_to eq(original_check_number)
      expect(result.replaced_check_number).to eq(original_check_number)
      expect(result.voided?).to eq(false) # the new replacement is the live check
      expect(result.gross_pay).to be_within(0.01).of(1200.00)
      expect(result.check_printed_at).to be_nil
      expect(result.check_print_count).to eq(0)

      events = result.check_events.reload.order(:created_at)
      expect(events.map(&:event_type)).to eq(%w[voided replaced])
      expect(events.first.check_number).to eq(original_check_number)
      expect(events.last.check_number).to eq(next_check_number.to_s)
      expect(events.last.reason).to include("Replace (uncashed, printed)")
    end

    it "subtracts the original from YTD then re-adds the corrected, leaving net delta of +300 gross" do
      original_gross_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay

      described_class.replace!(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 },
        reason:          "Returned uncashed; corrected hours",
        actor:           actor
      )

      new_gross_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay
      expect(new_gross_ytd).to be_within(0.01).of(original_gross_ytd + 300.00)
    end

    it "supports a smaller-amount replacement (overpayment recovery)" do
      original_gross_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay

      result = described_class.replace!(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 50 }, # -10h * $15 = -$150
        reason:          "Overpayment — original returned uncashed",
        actor:           actor
      )

      expect(result.gross_pay).to be_within(0.01).of(750.00)
      new_gross_ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024).gross_pay
      expect(new_gross_ytd).to be_within(0.01).of(original_gross_ytd - 150.00)
    end
  end

  # Regression for the date-cutoff bug in #ytd_excluding_self. The
  # PayrollCalculator uses this value as the "pre-period YTD" baseline
  # for SS-wage-base and FIT-bracket math. Without a `pay_date < ?`
  # filter, items from *later* committed periods in the same year would
  # leak in — distorting taxes on a mid-year replacement (e.g. zeroing
  # SS by falsely pushing the employee past the wage base, or bumping
  # them into a higher FIT bracket than was correct at the time).
  describe "#ytd_excluding_self date-cutoff (CPR / Greptile P1 regression)" do
    let!(:later_period) do
      create(:pay_period, :committed, company: company,
             start_date: Date.new(2024, 3, 1),
             end_date:   Date.new(2024, 3, 14),
             pay_date:   Date.new(2024, 3, 19))
    end
    let!(:later_item) do
      item = later_period.payroll_items.build(
        employee:        employee,
        company_id:      company.id,
        employment_type: "hourly",
        pay_rate:        15.00,
        hours_worked:    100
      )
      PayrollCalculator.for(employee, item).calculate
      item.save!
      EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
                      .add_payroll_item!(item)
      CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024)
                     .add_payroll_item!(item)
      company.assign_check_numbers!([item])
      item.reload
    end

    it "excludes items from later periods (and itself), even in the same year" do
      service = described_class.new(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 }
      )
      excluded_gross = service.send(:ytd_excluding_self, :gross_pay)

      # The early period is the only one before itself in the year.
      # later_item must NOT be included.
      expect(excluded_gross).to eq(0.0)
    end

    it "still includes items from earlier periods in the same year" do
      earlier_period = create(:pay_period, :committed, company: company,
                              start_date: Date.new(2023, 12, 18),
                              end_date:   Date.new(2023, 12, 31),
                              pay_date:   Date.new(2024, 1, 5))
      earlier_item = earlier_period.payroll_items.build(
        employee:        employee,
        company_id:      company.id,
        employment_type: "hourly",
        pay_rate:        15.00,
        hours_worked:    20
      )
      PayrollCalculator.for(employee, earlier_item).calculate
      earlier_item.save!

      service = described_class.new(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 }
      )
      excluded_gross = service.send(:ytd_excluding_self, :gross_pay)

      # Includes the Jan 5 earlier period (300.00) but excludes both the
      # original (being replaced) and the March later_item.
      expect(excluded_gross).to be_within(0.01).of(300.00)
    end

    it "produces SS tax on the replacement that matches an isolated 80h calc (no cross-period leak)" do
      # Establishes the bug's user-visible symptom: with the leak, taxes on
      # the replacement would be biased by later_item's 1500 contribution.
      # With the cutoff, the replacement's SS = 6.2% * 1200 = $74.40.
      result = described_class.replace!(
        payroll_item:    original_item,
        corrected_inputs: { hours_worked: 80 },
        reason:          "Mid-year replacement should ignore later periods",
        actor:           actor
      )
      expect(result.social_security_tax).to be_within(0.01).of(80 * 15 * 0.062)
      expect(result.medicare_tax).to be_within(0.01).of(80 * 15 * 0.0145)
    end
  end

  describe ".replace! — guard rails" do
    it "raises when no inputs change" do
      expect {
        described_class.replace!(
          payroll_item:    original_item,
          corrected_inputs: { hours_worked: 60 },
          reason:          "no actual change",
          actor:           actor
        )
      }.to raise_error(ReplaceCheckService::InvalidStateError, /No change/)
    end

    it "raises when corrected gross would be zero (use void instead)" do
      expect {
        described_class.replace!(
          payroll_item:    original_item,
          corrected_inputs: { hours_worked: 0, pay_rate: 0 },
          reason:          "Full reversal — use void flow",
          actor:           actor
        )
      }.to raise_error(ReplaceCheckService::InvalidInputError, /positive corrected gross/)
    end

    it "requires a reason of at least 10 characters" do
      expect {
        described_class.replace!(
          payroll_item:    original_item,
          corrected_inputs: { hours_worked: 80 },
          reason:          "too short",
          actor:           actor
        )
      }.to raise_error(ReplaceCheckService::InvalidInputError, /Reason is required/)
    end

    it "rejects an already-voided item" do
      original_item.update!(voided: true, voided_at: Time.current, voided_by_user_id: actor.id, void_reason: "test")
      expect {
        described_class.replace!(
          payroll_item:    original_item,
          corrected_inputs: { hours_worked: 80 },
          reason:          "Should fail — already voided",
          actor:           actor
        )
      }.to raise_error(ReplaceCheckService::InvalidStateError, /already-voided/)
    end

    # Regression for the multi-rate gap that surfaced live with Ma Cristina
    # Salas: she's a multi-rate pilot (Flight $30/hr, Admin $10/hr, Ground
    # $30/hr) whose check was committed with the wrong bucket
    # distribution (1h Admin instead of 14.3h Flight + 3.2h Ground). Without
    # `wage_rate_hours` in REPLACEABLE_INPUT_FIELDS, the operator could only
    # edit aggregate scalars — which the multi-rate calculator silently
    # overwrites from the OLD per-bucket entries — so the corrected gross
    # would never apply. These specs lock in that the bucket payload is
    # accepted, written through to custom_columns_data, and drives gross
    # recompute end-to-end.
    describe "multi-rate redistribution" do
      let(:multirate_employee) do
        create(:employee, company: company, department: department,
                          pay_rate: 30.00, pay_frequency: "biweekly",
                          filing_status: "single", allowances: 0)
      end
      let!(:multirate_item) do
        item = pay_period.payroll_items.build(
          employee:        multirate_employee,
          company_id:      company.id,
          employment_type: "hourly",
          pay_rate:        30.00
        )
        item.wage_rate_hours = [
          { "label" => "Flight Hours",  "rate" => 30.0, "regular_hours" => 0, "is_primary" => true },
          { "label" => "Admin Duties",  "rate" => 10.0, "regular_hours" => 1 },
          { "label" => "Ground Instr",  "rate" => 30.0, "regular_hours" => 0 }
        ]
        PayrollCalculator.for(multirate_employee, item).calculate
        item.save!
        EmployeeYtdTotal.find_or_create_by!(employee_id: multirate_employee.id, year: 2024).add_payroll_item!(item)
        CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024).add_payroll_item!(item)
        company.assign_check_numbers!([item])
        item.reload
      end

      it "redistributes hours across rate buckets and recomputes gross from the new bucket sums" do
        expect(multirate_item.gross_pay).to be_within(0.01).of(10.00) # 1h × $10 admin

        corrected_buckets = [
          { "label" => "Flight Hours", "rate" => 30.0, "regular_hours" => 14.3, "is_primary" => true },
          { "label" => "Admin Duties", "rate" => 10.0, "regular_hours" => 0 },
          { "label" => "Ground Instr", "rate" => 30.0, "regular_hours" => 3.2 }
        ]

        described_class.replace!(
          payroll_item:    multirate_item,
          corrected_inputs: { wage_rate_hours: corrected_buckets },
          reason:          "Wrong bucket distribution — corrected hours from client",
          actor:           actor
        )

        reloaded = multirate_item.reload
        # 14.3 * 30 + 3.2 * 30 = 429 + 96 = 525.00
        expect(reloaded.gross_pay).to be_within(0.01).of(525.00)
        # The calculator overwrites the aggregate scalars from the bucket sums:
        expect(reloaded.hours_worked.to_f).to be_within(0.001).of(17.5)
        # Bucket payload persisted through to custom_columns_data:
        expect(reloaded.wage_rate_hours.find { |b| b["label"] == "Flight Hours" }["regular_hours"]).to eq(14.3)
        expect(reloaded.wage_rate_hours.find { |b| b["label"] == "Admin Duties" }["regular_hours"]).to eq(0.0)
      end

      it "updates YTD by the gross delta, not the old aggregate scalars" do
        original_ytd = EmployeeYtdTotal.find_by(employee_id: multirate_employee.id, year: 2024).gross_pay

        described_class.replace!(
          payroll_item:    multirate_item,
          corrected_inputs: {
            wage_rate_hours: [
              { "label" => "Flight Hours", "rate" => 30.0, "regular_hours" => 14.3, "is_primary" => true },
              { "label" => "Admin Duties", "rate" => 10.0, "regular_hours" => 0 },
              { "label" => "Ground Instr", "rate" => 30.0, "regular_hours" => 3.2 }
            ]
          },
          reason:          "Wrong bucket distribution — corrected hours from client",
          actor:           actor
        )

        new_ytd = EmployeeYtdTotal.find_by(employee_id: multirate_employee.id, year: 2024).gross_pay
        expect(new_ytd - original_ytd).to be_within(0.01).of(515.00) # 525 - 10
      end

      it "flags zero_change when the bucket payload matches the existing breakdown" do
        result = described_class.preview(
          payroll_item:    multirate_item,
          corrected_inputs: {
            wage_rate_hours: [
              { "label" => "Flight Hours", "rate" => 30.0, "regular_hours" => 0, "is_primary" => true },
              { "label" => "Admin Duties", "rate" => 10.0, "regular_hours" => 1 },
              { "label" => "Ground Instr", "rate" => 30.0, "regular_hours" => 0 }
            ]
          }
        )
        expect(result[:meta][:is_zero_change]).to eq(true)
      end
    end

    it "rejects items on a supplemental period" do
      supplemental = create(:pay_period, :committed, company: company,
                            start_date: pay_period.start_date,
                            end_date:   pay_period.end_date,
                            pay_date:   pay_period.pay_date + 7,
                            cycle:      "supplemental",
                            corrects_pay_period_id: pay_period.id)
      sup_item = supplemental.payroll_items.create!(
        employee:        employee,
        company_id:      company.id,
        employment_type: "hourly",
        pay_rate:        15.00,
        hours_worked:    5,
        gross_pay:       75.00,
        net_pay:         70.00,
        check_number:    "9999",
        correction_for_payroll_item_id: original_item.id,
        correction_reason: "delta"
      )

      expect {
        described_class.replace!(
          payroll_item:    sup_item,
          corrected_inputs: { hours_worked: 8 },
          reason:          "Should reject supplemental",
          actor:           actor
        )
      }.to raise_error(ReplaceCheckService::InvalidStateError, /correct/)
    end
  end
end
