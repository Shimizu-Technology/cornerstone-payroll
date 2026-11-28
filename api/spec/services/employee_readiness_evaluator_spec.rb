# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeReadinessEvaluator do
  let(:company) { create(:company, name: "Harborview Bistro") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:rates_on) { Date.new(2026, 11, 22) }
  let(:w4_on) { Date.new(2026, 11, 27) }

  def add_w4!(employee, effective_on: Date.new(2026, 1, 1), signed_on: Date.new(2026, 1, 1), source: "client_direct", version: 2020)
    EmployeeW4Election.create!(
      EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
        company: employee.company,
        employee: employee,
        effective_on: effective_on,
        w4_signed_on: signed_on,
        w4_form_version: version,
        source: source,
        reason: "Test W-4 election"
      )
    )
  end

  def create_ready_w2_hourly(**overrides)
    employee = create(
      :employee,
      :hourly,
      company: company,
      first_name: "Jordan",
      last_name: "Sample",
      date_of_birth: Date.new(1994, 5, 14),
      hire_date: Date.new(2026, 11, 1),
      pay_rate: 18.50,
      pay_frequency: "biweekly",
      payment_delivery_method: "paper_check",
      readiness_gate_enforced: true,
      **overrides
    )
    add_w4!(employee, effective_on: Date.new(2026, 11, 1), signed_on: Date.new(2026, 11, 1))
    employee
  end

  describe "checklist matrix across every worker type" do
    it "marks a complete W-2 hourly single-rate hire Ready" do
      employee = create_ready_w2_hourly

      result = described_class.evaluate(employee, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_ready
      expect(result).not_to be_incomplete
      expect(result).not_to be_hard_blocked
      expect(result.status).to eq("ready")
      expect(result.missing_keys).to eq([])
      expect(result.reason).to be_nil
    end

    it "marks a W-2 multi-rate hourly hire Ready via active positive wage rates even when base pay_rate is 0" do
      employee = create_ready_w2_hourly(pay_rate: 0)
      EmployeeWageRate.create!(employee: employee, label: "Barista", rate: 16.00, is_primary: true, active: true)

      result = described_class.evaluate(employee.reload, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_ready
      expect(result.missing_keys).to eq([])
    end

    it "marks W-2 fixed salary (annual and per_period) Ready only when pay_rate > 0" do
      %w[annual per_period].each do |salary_type|
        ready = create_ready_w2_hourly(employment_type: "salary", salary_type: salary_type, pay_rate: 2_000.00)
        expect(described_class.evaluate(ready, rates_on: rates_on, w4_on: w4_on)).to be_ready

        zero = create_ready_w2_hourly(employment_type: "salary", salary_type: salary_type, pay_rate: 0)
        result = described_class.evaluate(zero, rates_on: rates_on, w4_on: w4_on)
        expect(result).to be_incomplete
        expect(result.missing_keys).to eq([ "pay_setup" ])
        expect(result.reason).to eq("Can't be paid yet: pay rate missing.")
      end
    end

    it "marks W-2 variable salary Ready even when pay_rate is 0" do
      variable = create_ready_w2_hourly(employment_type: "salary", salary_type: "variable", pay_rate: 0)

      result = described_class.evaluate(variable, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_ready
      expect(result.missing_keys).to eq([])
    end

    it "evaluates 1099 individual contractors (hourly and flat_fee) with SSN or EIN, optional DOB, and W-9" do
      flat_fee_ssn = create(
        :employee,
        :contractor,
        company: company,
        first_name: "Morgan",
        last_name: "Example",
        contractor_type: "individual",
        contractor_pay_type: "flat_fee",
        pay_rate: 0,
        date_of_birth: nil,
        hire_date: Date.new(2026, 11, 1),
        w9_on_file: true,
        payment_delivery_method: "direct_deposit",
        readiness_gate_enforced: true
      )
      result = described_class.evaluate(flat_fee_ssn, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_ready
      expect(result.items.find { |i| i.key == "date_of_birth" }.applicable).to be(false)
      expect(result).to be_direct_deposit_missing_bank_details
      expect(result.items.find { |i| i.key == "payment_method" }.metadata[:direct_deposit_missing_bank_details]).to be(true)

      individual_ein = create(
        :employee,
        :contractor,
        company: company,
        first_name: "Riley",
        last_name: "Example",
        contractor_type: "individual",
        contractor_pay_type: "hourly",
        pay_rate: 45.00,
        ssn_encrypted: nil,
        contractor_ein: "98-1234567",
        date_of_birth: nil,
        hire_date: Date.new(2026, 11, 1),
        w9_on_file: true,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      expect(described_class.evaluate(individual_ein, rates_on: rates_on, w4_on: w4_on)).to be_ready

      hourly_zero = create(
        :employee,
        :contractor,
        company: company,
        contractor_type: "individual",
        contractor_pay_type: "hourly",
        pay_rate: 0,
        hire_date: Date.new(2026, 11, 1),
        w9_on_file: false,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      missing = described_class.evaluate(hourly_zero, rates_on: rates_on, w4_on: w4_on)
      expect(missing.missing_keys).to eq(%w[pay_setup tax_form])
      expect(missing.reason).to eq("Can't be paid yet: pay rate missing and W-9 not marked on file.")
    end

    it "evaluates 1099 business contractors requiring business_name, 9-digit EIN (not SSN alone), and W-9" do
      business_incomplete = create(
        :employee,
        :business_contractor,
        company: company,
        business_name: nil,
        contractor_ein: nil,
        ssn_encrypted: "100-70-9001",
        contractor_pay_type: "hourly",
        pay_rate: 50.00,
        hire_date: Date.new(2026, 11, 1),
        w9_on_file: false,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      result = described_class.evaluate(business_incomplete, rates_on: rates_on, w4_on: w4_on)
      expect(result.missing_keys).to eq(%w[legal_name tax_id tax_form])
      expect(result.items.find { |i| i.key == "legal_name" }.missing_label).to eq("business name missing")
      expect(result.items.find { |i| i.key == "tax_id" }.missing_label).to eq("business EIN missing")
      expect(result.reason).to eq("Can't be paid yet: business name missing, business EIN missing, and 1 more item.")

      business_ready = create(
        :employee,
        :business_contractor,
        company: company,
        business_name: "Pacific Trade Works LLC",
        contractor_ein: "98-7654321",
        contractor_pay_type: "flat_fee",
        pay_rate: 0,
        hire_date: Date.new(2026, 11, 1),
        w9_on_file: true,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      expect(described_class.evaluate(business_ready, rates_on: rates_on, w4_on: w4_on)).to be_ready
    end
  end

  describe "period-dated W-4s, pay rates, hire dates, and default withholding" do
    it "fails a future-dated W-4 for an earlier payday with a dated reason, then passes on the later payday" do
      employee = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: Date.new(1992, 3, 10),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 20.00,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      add_w4!(employee, effective_on: Date.new(2026, 12, 15), signed_on: Date.new(2026, 12, 1))

      earlier = described_class.evaluate(employee, rates_on: Date.new(2026, 11, 22), w4_on: Date.new(2026, 11, 30))
      expect(earlier).to be_incomplete
      expect(earlier.missing_keys).to eq([ "tax_form" ])
      expect(earlier.reason).to eq("Can't be paid yet: W-4 not effective until Dec 15, 2026 — missing for Nov 30, 2026 payday.")

      later = described_class.evaluate(employee, rates_on: Date.new(2026, 12, 13), w4_on: Date.new(2026, 12, 15))
      expect(later).to be_ready
    end

    it "keeps tax_form missing when only a default_withholding W-4 exists" do
      employee = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: Date.new(1992, 3, 10),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 20.00,
        payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      add_w4!(employee, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "default_withholding")

      result = described_class.evaluate(employee, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_incomplete
      expect(result.missing_keys).to eq([ "tax_form" ])
      expect(result.reason).to eq("Can't be paid yet: W-4 missing.")
    end

    it "evaluates period-dated pay rates and future-dated wage rates accurately" do
      employee = create_ready_w2_hourly(pay_rate: 0)
      EmployeeCompensationChangeService.new(
        employee: employee,
        actor: actor,
        source: "operator",
        reason: "Scheduled starting hourly rate",
        effective_on: Date.new(2026, 12, 1),
        pay_rate: 22.00
      ).call!

      earlier = described_class.evaluate(employee.reload, rates_on: Date.new(2026, 11, 22), w4_on: Date.new(2026, 11, 27))
      expect(earlier).to be_incomplete
      expect(earlier.missing_keys).to eq([ "pay_setup" ])
      expect(earlier.reason).to include("pay rate not effective until Dec 1, 2026")

      later = described_class.evaluate(employee, rates_on: Date.new(2026, 12, 6), w4_on: Date.new(2026, 12, 11))
      expect(later).to be_ready
    end

    it "fails a future hire_date for an earlier pay period" do
      employee = create_ready_w2_hourly(hire_date: Date.new(2026, 12, 1))

      earlier = described_class.evaluate(employee, rates_on: Date.new(2026, 11, 22), w4_on: Date.new(2026, 11, 27))
      expect(earlier.missing_keys).to eq([ "hire_date" ])
      expect(earlier.reason).to include("hire date not effective until Dec 1, 2026")

      later = described_class.evaluate(employee, rates_on: Date.new(2026, 12, 6), w4_on: Date.new(2026, 12, 11))
      expect(later).to be_ready
    end
  end

  describe "grandfathered employees, rehires, and payment method semantics" do
    it "never hard-blocks grandfathered employees and treats NULL payment_delivery_method as paper_check" do
      grandfathered = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: nil,
        hire_date: Date.new(2024, 1, 1),
        pay_rate: 17.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: false
      )
      add_w4!(grandfathered, effective_on: Date.new(2019, 1, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      result = described_class.evaluate(grandfathered, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_incomplete
      expect(result).not_to be_hard_blocked
      expect(result.status).to eq("missing_items")
      # Only DOB is missing: legacy 2019 W-4 and NULL payment method are both accepted for grandfathered workers.
      expect(result.missing_keys).to eq([ "date_of_birth" ])
    end

    it "requires explicit payment_delivery_method and 2020+ W-4 for brand-new client hires, but accepts legacy W-4 and NULL payment method on rehire" do
      new_hire = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: Date.new(1990, 8, 1),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 19.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(new_hire, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      before_rehire = described_class.evaluate(new_hire, rates_on: rates_on, w4_on: w4_on)
      expect(before_rehire).to be_hard_blocked
      expect(before_rehire.missing_keys).to eq(%w[tax_form payment_method])

      EmployeeStatusEvent.create!(
        company: company,
        employee: new_hire,
        event_type: "terminated",
        previous_status: "active",
        resulting_status: "terminated",
        effective_date: Date.new(2026, 11, 2),
        source: "client_portal"
      )
      EmployeeStatusEvent.create!(
        company: company,
        employee: new_hire,
        event_type: "reactivated",
        previous_status: "terminated",
        resulting_status: "active",
        effective_date: Date.new(2026, 11, 10),
        source: "client_portal"
      )

      after_rehire = described_class.evaluate(new_hire.reload, rates_on: rates_on, w4_on: w4_on)
      expect(after_rehire).to be_ready
      expect(after_rehire.rehire_or_grandfathered).to be(true)
    end

    it "does not treat deactivation and reactivation as a rehire for gated new hires" do
      new_hire = create(
        :employee,
        :hourly,
        company: company,
        date_of_birth: Date.new(1990, 8, 1),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 19.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(new_hire, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      EmployeeStatusEvent.create!(
        company: company,
        employee: new_hire,
        event_type: "deactivated",
        previous_status: "active",
        resulting_status: "inactive",
        effective_date: Date.new(2026, 11, 2),
        source: "client_portal"
      )
      EmployeeStatusEvent.create!(
        company: company,
        employee: new_hire,
        event_type: "reactivated",
        previous_status: "inactive",
        resulting_status: "active",
        effective_date: Date.new(2026, 11, 10),
        source: "client_portal"
      )

      result = described_class.evaluate(new_hire.reload, rates_on: rates_on, w4_on: w4_on)
      expect(result).to be_hard_blocked
      expect(result.rehire_or_grandfathered).to be(false)
      expect(result.missing_keys).to eq(%w[tax_form payment_method])
    end

    it "resolves default target dates from the company's next open regular pay period or Guam today" do
      expect(described_class.target_dates_for(company)).to eq([ PayrollBusinessClock.today, PayrollBusinessClock.today ])

      create(:pay_period, company: company, status: "committed", start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 14), pay_date: Date.new(2026, 10, 20))
      create(:pay_period, company: company, status: "draft", run_purpose: "bonus", start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 2), pay_date: Date.new(2026, 11, 5))
      next_regular = create(:pay_period, company: company, status: "draft", run_purpose: "regular", start_date: Date.new(2026, 11, 9), end_date: Date.new(2026, 11, 22), pay_date: Date.new(2026, 11, 27))
      create(:pay_period, company: company, status: "draft", run_purpose: "regular", start_date: Date.new(2026, 11, 23), end_date: Date.new(2026, 12, 6), pay_date: Date.new(2026, 12, 11))

      expect(described_class.target_dates_for(company)).to eq([ next_regular.end_date, next_regular.pay_date ])
    end
  end

  describe "SQL / Ruby parity with Employee.readiness_incomplete_for_period" do
    it "matches EmployeeReadinessEvaluator.incomplete? across every worker type and period edge case" do
      committed_period = create(
        :pay_period,
        :committed,
        company: company,
        start_date: Date.new(2026, 10, 12),
        end_date: Date.new(2026, 10, 25),
        pay_date: Date.new(2026, 10, 30)
      )

      ready_w2 = create_ready_w2_hourly
      ready_multirate = create_ready_w2_hourly(pay_rate: 0)
      EmployeeWageRate.create!(employee: ready_multirate, label: "Kitchen", rate: 17.50, is_primary: true, active: true)

      future_rate_w2 = create_ready_w2_hourly(pay_rate: 0)
      EmployeeCompensationChangeService.new(
        employee: future_rate_w2, actor: actor, source: "operator", reason: "Future hourly rate",
        effective_on: Date.new(2026, 12, 1), pay_rate: 21.00
      ).call!

      future_wage_rate_w2 = create_ready_w2_hourly(pay_rate: 0)
      EmployeeCompensationChangeService.new(
        employee: future_wage_rate_w2, actor: actor, source: "operator", reason: "Future secondary wage rate",
        effective_on: Date.new(2026, 12, 1),
        wage_rate_edits: [ { label: "Server", rate: 15.00, active: true, is_primary: true } ]
      ).call!

      ready_variable_salary = create_ready_w2_hourly(employment_type: "salary", salary_type: "variable", pay_rate: 0)
      zero_fixed_salary = create_ready_w2_hourly(employment_type: "salary", salary_type: "annual", pay_rate: 0)

      future_w4 = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1993, 2, 1),
        hire_date: Date.new(2026, 11, 1), pay_rate: 18.00, payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      add_w4!(future_w4, effective_on: Date.new(2026, 12, 15), signed_on: Date.new(2026, 12, 1))

      default_w4_only = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1993, 2, 1),
        hire_date: Date.new(2026, 11, 1), pay_rate: 18.00, payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      add_w4!(default_w4_only, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "default_withholding")

      new_hire_null_payment = create_ready_w2_hourly(payment_delivery_method: nil)

      new_hire_legacy_w4 = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1991, 4, 4),
        hire_date: Date.new(2026, 11, 1), pay_rate: 18.00, payment_delivery_method: "paper_check",
        readiness_gate_enforced: true
      )
      add_w4!(new_hire_legacy_w4, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      rehire_legacy_and_null_pay = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1991, 4, 4),
        hire_date: Date.new(2026, 11, 1), pay_rate: 18.00, payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(rehire_legacy_and_null_pay, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)
      EmployeeStatusEvent.create!(
        company: company, employee: rehire_legacy_and_null_pay,
        event_type: "reactivated", previous_status: "terminated", resulting_status: "active",
        effective_date: Date.new(2026, 11, 5), source: "client_portal"
      )

      prior_paid_null_pay = create_ready_w2_hourly(hire_date: Date.new(2026, 10, 1), payment_delivery_method: nil)
      create(:payroll_item, company: company, pay_period: committed_period, employee: prior_paid_null_pay, pay_rate: 18.50)

      grandfathered_complete_null_pay = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1985, 7, 7),
        hire_date: Date.new(2024, 1, 1), pay_rate: 18.00, payment_delivery_method: nil,
        readiness_gate_enforced: false
      )
      add_w4!(grandfathered_complete_null_pay, effective_on: Date.new(2024, 1, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      grandfathered_missing_dob = create(
        :employee, :hourly, company: company, date_of_birth: nil,
        hire_date: Date.new(2024, 1, 1), pay_rate: 18.00, payment_delivery_method: nil,
        readiness_gate_enforced: false
      )
      add_w4!(grandfathered_missing_dob, effective_on: Date.new(2024, 1, 1), signed_on: nil, source: "legacy_profile", version: 2020)

      partial_new_hire = create(
        :employee, :hourly, company: company,
        ssn_encrypted: nil, date_of_birth: nil, hire_date: nil,
        address_line1: nil, city: nil, state: nil, zip: nil,
        pay_rate: 0, payment_delivery_method: nil,
        readiness_gate_enforced: true
      )

      contractor_individual_ready = create(
        :employee, :contractor, company: company, contractor_type: "individual", contractor_pay_type: "flat_fee",
        pay_rate: 0, date_of_birth: nil, hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "direct_deposit", readiness_gate_enforced: true
      )

      contractor_business_missing_ein = create(
        :employee, :business_contractor, company: company, business_name: "Lagoon Builders LLC",
        contractor_ein: nil, contractor_pay_type: "flat_fee", pay_rate: 0,
        hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )

      contractor_business_ready = create(
        :employee, :business_contractor, company: company, business_name: "Coral Design LLC",
        contractor_ein: "98-1122334", contractor_pay_type: "hourly", pay_rate: 60.00,
        hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )

      short_ssn_w2 = create_ready_w2_hourly
      short_ssn_w2.ssn_encrypted = "12345"
      short_ssn_w2.save!(validate: false)

      short_ein_business = create(
        :employee, :business_contractor, company: company, business_name: "Short EIN Works LLC",
        contractor_ein: "98-1122334", contractor_pay_type: "flat_fee", pay_rate: 0,
        hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )
      short_ein_business.contractor_ein = "12-34"
      short_ein_business.save!(validate: false)

      short_tin_individual = create(
        :employee, :contractor, company: company, contractor_type: "individual", contractor_pay_type: "flat_fee",
        pay_rate: 0, date_of_birth: nil, hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )
      short_tin_individual.ssn_encrypted = "12345"
      short_tin_individual.contractor_ein = "12-34"
      short_tin_individual.save!(validate: false)

      short_ssn_valid_ein_individual = create(
        :employee, :contractor, company: company, contractor_type: "individual", contractor_pay_type: "flat_fee",
        pay_rate: 0, date_of_birth: nil, hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )
      short_ssn_valid_ein_individual.ssn_encrypted = "12345"
      short_ssn_valid_ein_individual.contractor_ein = "98-7654321"
      short_ssn_valid_ein_individual.save!(validate: false)

      null_pay_frequency_comp = create_ready_w2_hourly
      null_pay_frequency_comp.employee_compensation_changes.first!.update_columns(pay_frequency: nil)

      null_salary_type_comp = create_ready_w2_hourly(employment_type: "salary", salary_type: "annual", pay_rate: 52_000.00)
      null_salary_type_comp.employee_compensation_changes.first!.update_columns(salary_type: nil)

      null_contractor_pay_type_comp = create(
        :employee, :contractor, company: company, contractor_type: "individual", contractor_pay_type: "flat_fee",
        pay_rate: 500.00, date_of_birth: nil, hire_date: Date.new(2026, 11, 1), w9_on_file: true,
        payment_delivery_method: "paper_check", readiness_gate_enforced: true
      )
      null_contractor_pay_type_comp.employee_compensation_changes.first!.update_columns(contractor_pay_type: nil)

      deactivated_reactivated_new_hire = create(
        :employee, :hourly, company: company, date_of_birth: Date.new(1991, 4, 4),
        hire_date: Date.new(2026, 11, 1), pay_rate: 18.00, payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(deactivated_reactivated_new_hire, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)
      EmployeeStatusEvent.create!(
        company: company, employee: deactivated_reactivated_new_hire,
        event_type: "deactivated", previous_status: "active", resulting_status: "inactive",
        effective_date: Date.new(2026, 11, 2), source: "client_portal"
      )
      EmployeeStatusEvent.create!(
        company: company, employee: deactivated_reactivated_new_hire,
        event_type: "reactivated", previous_status: "inactive", resulting_status: "active",
        effective_date: Date.new(2026, 11, 5), source: "client_portal"
      )

      nbsp_first_name = create_ready_w2_hourly
      nbsp_first_name.update_columns(first_name: "\u00A0")

      ideographic_space_city = create_ready_w2_hourly
      ideographic_space_city.update_columns(city: "\u3000")

      population = [
        ready_w2, ready_multirate, future_rate_w2, future_wage_rate_w2,
        ready_variable_salary, zero_fixed_salary, future_w4, default_w4_only,
        new_hire_null_payment, new_hire_legacy_w4, rehire_legacy_and_null_pay,
        prior_paid_null_pay, grandfathered_complete_null_pay, grandfathered_missing_dob,
        partial_new_hire, contractor_individual_ready, contractor_business_missing_ein,
        contractor_business_ready, short_ssn_w2, short_ein_business,
        short_tin_individual, short_ssn_valid_ein_individual,
        null_pay_frequency_comp, null_salary_type_comp, null_contractor_pay_type_comp,
        deactivated_reactivated_new_hire, nbsp_first_name, ideographic_space_city
      ].map(&:reload)

      must_be_incomplete_ids = [
        short_ssn_w2.id,
        short_ein_business.id,
        short_tin_individual.id,
        null_pay_frequency_comp.id,
        null_salary_type_comp.id,
        null_contractor_pay_type_comp.id,
        deactivated_reactivated_new_hire.id,
        nbsp_first_name.id,
        ideographic_space_city.id
      ]

      [
        [ Date.new(2026, 11, 22), Date.new(2026, 11, 27) ],
        [ Date.new(2026, 12, 6), Date.new(2026, 12, 15) ]
      ].each do |period_rates_on, period_w4_on|
        ruby_incomplete_ids = population.select do |emp|
          described_class.incomplete?(emp, rates_on: period_rates_on, w4_on: period_w4_on)
        end.map(&:id)

        sql_incomplete_ids = Employee.where(id: population.map(&:id))
          .readiness_incomplete_for_period(rates_on: period_rates_on, w4_on: period_w4_on)
          .pluck(:id)

        expect(ruby_incomplete_ids).to include(*must_be_incomplete_ids)
        expect(ruby_incomplete_ids).not_to include(short_ssn_valid_ein_individual.id)
        expect(sql_incomplete_ids).to match_array(ruby_incomplete_ids),
          "SQL/Ruby mismatch for rates_on=#{period_rates_on}, w4_on=#{period_w4_on}: " \
          "sql_only=#{sql_incomplete_ids - ruby_incomplete_ids}, ruby_only=#{ruby_incomplete_ids - sql_incomplete_ids}"
      end
    end
  end

  describe ".evaluate_batch parity with .evaluate (N6, nil-company fallback)" do
    it "matches .evaluate across new hire, rehire, grandfathered, and prior committed pay with and without rates_on" do
      committed_period = create(
        :pay_period,
        :committed,
        company: company,
        start_date: Date.new(2026, 10, 12),
        end_date: Date.new(2026, 10, 25),
        pay_date: Date.new(2026, 10, 30)
      )
      open_period = create(
        :pay_period,
        company: company,
        status: "draft",
        run_purpose: "regular",
        start_date: Date.new(2026, 11, 9),
        end_date: Date.new(2026, 11, 22),
        pay_date: Date.new(2026, 11, 27)
      )

      new_hire_incomplete = create(
        :employee, :hourly, company: company,
        date_of_birth: Date.new(1994, 5, 14),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 19.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(new_hire_incomplete, effective_on: Date.new(2026, 12, 1), signed_on: Date.new(2026, 11, 15))

      rehire_worker = create(
        :employee, :hourly, company: company,
        date_of_birth: Date.new(1991, 4, 4),
        hire_date: Date.new(2026, 11, 1),
        pay_rate: 18.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      add_w4!(rehire_worker, effective_on: Date.new(2026, 11, 1), signed_on: nil, source: "legacy_profile", version: 2019)
      EmployeeStatusEvent.create!(
        company: company,
        employee: rehire_worker,
        event_type: "reactivated",
        previous_status: "terminated",
        resulting_status: "active",
        effective_date: Date.new(2026, 11, 5),
        source: "client_portal"
      )

      grandfathered_worker = create(
        :employee, :hourly, company: company,
        date_of_birth: nil,
        hire_date: Date.new(2024, 1, 1),
        pay_rate: 18.00,
        payment_delivery_method: nil,
        readiness_gate_enforced: false
      )
      add_w4!(grandfathered_worker, effective_on: Date.new(2024, 1, 1), signed_on: nil, source: "legacy_profile", version: 2019)

      prior_paid_worker = create_ready_w2_hourly(hire_date: Date.new(2026, 10, 1), payment_delivery_method: nil)
      create(:payroll_item, company: company, pay_period: committed_period, employee: prior_paid_worker, pay_rate: 18.50)

      rows = [ new_hire_incomplete, rehire_worker, grandfathered_worker, prior_paid_worker ].map(&:reload)

      [
        {},
        { rates_on: open_period.end_date },
        { rates_on: Date.new(2026, 12, 6), w4_on: Date.new(2026, 12, 11) }
      ].each do |date_opts|
        batched = described_class.evaluate_batch(rows, company: company, **date_opts)
        expect(batched.keys).to match_array(rows.map(&:id))
        rows.each do |row|
          expected = described_class.evaluate(row, **date_opts).as_json
          expect(batched.fetch(row.id).as_json).to eq(expected),
            "Parity mismatch for employee #{row.id} with #{date_opts.inspect}"
        end
      end

      # Nil-company fallback handles readiness_gate_enforced rows consistently without raising
      nil_company_batch = described_class.evaluate_batch(rows, company: nil, rates_on: open_period.end_date, w4_on: open_period.pay_date)
      rows.each do |row|
        expected = described_class.evaluate(row, rates_on: open_period.end_date, w4_on: open_period.pay_date).as_json
        expect(nil_company_batch.fetch(row.id).as_json).to eq(expected)
      end
    end
  end
end
