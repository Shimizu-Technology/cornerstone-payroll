# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Retained manual correction pay basis", type: :request do
  let!(:tax_configuration) { load Rails.root.join("db/seeds/tax_configs.rb") }
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company, pay_rate: 25, pay_frequency: "biweekly") }
  let!(:rate) { create(:employee_wage_rate, employee: employee, rate: 25, label: "Retained hourly", is_primary: true) }
  let!(:source_period) do
    create(:pay_period, :voided, company: company, start_date: "2026-10-01", end_date: "2026-10-15", pay_date: "2026-10-30")
  end
  let!(:source_item) do
    original = create(:payroll_item, company: company, employee: employee, pay_period: source_period,
      employment_type: "hourly", pay_rate: 25, hours_worked: 4, gross_pay: 100,
      wage_rate_hours: [ { "employee_wage_rate_id" => rate.id, "label" => rate.label, "rate" => 25,
        "regular_hours" => 4, "overtime_hours" => 0, "is_primary" => true, "active" => true } ])
    PayrollCalculator.for(employee, original).calculate
    original.save!
    original
  end
  let!(:period) do
    PayPeriodCorrectionService.create_correction_run!(source_pay_period: source_period, actor: actor,
      reason: "Synthetic retained manual correction")
  end
  let(:item) { period.payroll_items.sole }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    [ Api::V1::Admin::PayPeriodsController, Api::V1::Admin::PayrollItemsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    end
  end

  def frozen_financial_state
    [ item.reload.attributes, item.payroll_item_earnings.reload.order(:id).map(&:attributes),
      item.payroll_item_field_entries.reload.order(:id).map(&:attributes), item.loan_transactions.reload.order(:id).map(&:attributes),
      source_item.reload.attributes, source_item.payroll_item_earnings.reload.order(:id).map(&:attributes) ]
  end

  def change_to_salary!
    employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
  end

  it "rejects a worksheet calculation before hours, fields or loan drafts change" do
    original = frozen_financial_state
    change_to_salary!
    expect_any_instance_of(PayrollFieldInputApplier).not_to receive(:apply!)
    expect(NamedPayrollLoanInput).not_to receive(:apply!)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", headers: headers,
      params: { employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: 3 } },
        payroll_field_inputs: { employee.id.to_s => { "999" => { mode: "override", amount: 10 } } },
        named_loan_payments: { employee.id.to_s => { "999" => { mode: "override", amount: 20 } } } }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "success")).to be_empty
    expect(response.parsed_body.dig("results", "errors")).to contain_exactly(include("employee_id" => employee.id,
      "error" => include("pay basis differs", "linked original payroll")))
    expect(frozen_financial_state).to eq(original)
    expect(period.reload.status).to eq("draft")
  end

  it "rejects direct item recalculation without changing saved financial rows" do
    original = frozen_financial_state
    change_to_salary!
    post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(include("pay basis differs"))
    expect(frozen_financial_state).to eq(original)
  end

  it "rejects an editor update before applying fields or hourly inputs" do
    original = frozen_financial_state
    change_to_salary!
    patch "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}", headers: headers,
      params: { payroll_item: { hours_worked: 3, pay_rate: 52_000, bonus: 20 }, auto_calculate: true }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(frozen_financial_state).to eq(original)
  end

  it "protects direct calculation and input saves while allowing operational metadata" do
    original = frozen_financial_state
    item.employee # Retain a stale association to prove the guard reads current setup.
    change_to_salary!
    expect { item.calculate! }.to raise_error(ArgumentError, /pay basis differs/)
    expect(frozen_financial_state).to eq(original)
    expect(item.update(hours_worked: 3)).to eq(false)
    expect(item.errors.full_messages).to include(include("pay basis differs"))
    expect(frozen_financial_state).to eq(original)
    expect(item.update(check_print_count: 1)).to eq(true)
    expect(item.reload.pay_rate).to eq(25)
  end

  it "keeps retained scalar and bucket rates for a same-basis hourly correction despite a profile rate edit" do
    original_source = source_item.reload.attributes
    rate.update!(rate: 99)
    employee.update!(pay_rate: 99)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", headers: headers,
      params: { employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [
        { employee_wage_rate_id: rate.id, label: rate.label, rate: 25, regular_hours: 3, overtime_hours: 0, is_primary: true, active: true }
      ] } } }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(item.reload.pay_rate).to eq(25)
    expect(item.wage_rate_hours.sole["rate"]).to eq(25)
    expect(item.gross_pay).to eq(75)
    post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(item.reload.pay_rate).to eq(25)
    expect(item.gross_pay).to eq(75)
    expect(source_item.reload.attributes).to eq(original_source)
  end

  it "holds changed hourly frequency before recalculation even though retained gross would stay the same" do
    original = frozen_financial_state
    expect(source_item.gross_pay).to eq(100)
    employee.update!(pay_frequency: "semimonthly")
    post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(include("pay frequency differs"))
    expect(frozen_financial_state).to eq(original)
  end

  it "holds missing legacy hourly frequency without guessing from matching current defaults" do
    source_item.update_columns(calculation_context_snapshot: {})
    original = frozen_financial_state
    expect { item.calculate! }.to raise_error(ArgumentError, /original hourly pay frequency is missing/)
    expect(frozen_financial_state).to eq(original)
    expect(item.update(check_print_count: 1)).to eq(true)
  end

  context "a retained hourly contractor" do
    let!(:employee) { create(:employee, :contractor, company: company, contractor_pay_type: "hourly", pay_rate: 25) }
    let!(:source_item) do
      original = create(:payroll_item, company: company, employee: employee, pay_period: source_period,
        employment_type: "contractor", pay_rate: 25, hours_worked: 4)
      PayrollCalculator.for(employee, original).calculate
      original.save!
      original
    end

    it "rejects a changed contractor basis from captured evidence without replaying or inventing context" do
      original = frozen_financial_state
      employee.update!(contractor_pay_type: "flat_fee", pay_rate: 500)
      expect { item.calculate! }.to raise_error(ArgumentError, /pay basis differs/)
      expect(frozen_financial_state).to eq(original)
    end

    it "supports the recorded hourly basis and preserves original scalar after a current amount edit" do
      employee.update!(pay_rate: 99)
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate).to eq(25)
      expect(item.gross_pay).to eq(100)
    end

    it "holds legacy missing subtype without changing financial rows or blocking print metadata" do
      source_item.update_columns(calculation_context_snapshot: {})
      original = frozen_financial_state
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to include(include("original contractor pay basis is missing"))
      expect(frozen_financial_state).to eq(original)
      expect(item.update(check_print_count: 1)).to eq(true)
    end
  end

  context "a retained annual salary" do
    let!(:employee) { create(:employee, :salary, company: company, salary_type: "annual", pay_rate: 52_000, pay_frequency: "biweekly") }
    let(:retain_timekeeping_context) { false }
    let!(:source_item) do
      original = create(:payroll_item, :salary, company: company, employee: employee, pay_period: source_period,
        pay_rate: 52_000, hours_worked: 0)
      if retain_timekeeping_context
        CompanyWorkweek.create!(company: company, effective_on: "2020-01-01", starts_on_weekday: 0,
          starts_at_minutes: 0, timezone: "Pacific/Guam", confirmation_status: "confirmed", confirmed_by: actor,
          confirmed_at: Time.current, notes: "Confirmed salary schedule fixture")
        create(:employee_work_profile, employee: employee, effective_on: "2020-01-01")
        PayrollTimeAllocationService.call!(payroll_item: original)
      end
      PayrollCalculator.for(employee, original).calculate
      original.save!
      original
    end

    it "preserves recorded annual salary and scalar despite a current profile amount edit" do
      employee.update!(pay_rate: 78_000)
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate).to eq(52_000)
      expect(item.gross_pay).to eq(2000)
    end

    it "holds a changed salary subtype without reinterpreting annual pay as period pay" do
      original = frozen_financial_state
      employee.update!(salary_type: "per_period", pay_rate: 2000)
      expect { item.calculate! }.to raise_error(ArgumentError, /pay basis differs/)
      expect(frozen_financial_state).to eq(original)
    end

    it "holds legacy missing salary subtype without changing financial history" do
      source_item.update_columns(calculation_context_snapshot: {})
      original = frozen_financial_state
      expect { item.calculate! }.to raise_error(ArgumentError, /original salary pay basis is missing/)
      expect(frozen_financial_state).to eq(original)
      expect(item.update(check_print_count: 1)).to eq(true)
    end

    it "rejects biweekly to semimonthly frequency before worksheet or item input effects" do
      original = frozen_financial_state
      expect(source_item.gross_pay).to eq(2000)
      employee.update!(pay_frequency: "semimonthly")
      expect_any_instance_of(PayrollFieldInputApplier).not_to receive(:apply!)
      expect(NamedPayrollLoanInput).not_to receive(:apply!)
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", headers: headers,
        params: { employee_ids: [ employee.id ], salary_overrides: { employee.id.to_s => 2166.67 },
          payroll_field_inputs: { employee.id.to_s => { "999" => { mode: "override", amount: 10 } } },
          named_loan_payments: { employee.id.to_s => { "999" => { mode: "override", amount: 20 } } } }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("results", "success")).to be_empty
      expect(response.parsed_body.dig("results", "errors")).to contain_exactly(include("error" => include("pay frequency differs")))
      expect(frozen_financial_state).to eq(original)
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(frozen_financial_state).to eq(original)
      expect { item.calculate! }.to raise_error(ArgumentError, /pay frequency differs/)
      expect(frozen_financial_state).to eq(original)
    end

    it "holds missing original frequency despite today's matching employee and company defaults" do
      snapshot = source_item.calculation_context_snapshot.deep_dup
      snapshot.fetch("employee").delete("pay_frequency")
      source_item.update_columns(calculation_context_snapshot: snapshot)
      original = frozen_financial_state
      expect(company.pay_frequency).to eq("biweekly")
      expect { item.calculate! }.to raise_error(ArgumentError, /original salary pay frequency is missing/)
      expect(frozen_financial_state).to eq(original)
      expect(item.update(check_print_count: 1)).to eq(true)
    end

    context "a retained salary timekeeping schedule" do
      let(:retain_timekeeping_context) { true }

      it "uses the actual original employee frequency from its normal-engine schedule snapshot" do
        expect(source_item.timekeeping_context_snapshot).to include("pay_basis" => "salary", "pay_frequency" => "biweekly")
        snapshot = source_item.calculation_context_snapshot.deep_dup
        snapshot.fetch("employee").delete("pay_frequency")
        source_item.update_columns(calculation_context_snapshot: snapshot)
        post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
        expect(response).to have_http_status(:ok), response.body
        expect(item.reload.pay_rate).to eq(52_000)
        expect(item.gross_pay).to eq(2000)
      end

      it "holds conflicting recorded frequency rather than choosing the convenient snapshot" do
        snapshot = source_item.calculation_context_snapshot.deep_dup
        snapshot.fetch("employee")["pay_frequency"] = "semimonthly"
        source_item.update_columns(calculation_context_snapshot: snapshot)
        original = frozen_financial_state
        expect { item.calculate! }.to raise_error(ArgumentError, /frequency is missing, unverified or inconsistent/)
        expect(frozen_financial_state).to eq(original)
      end
    end

    context "a retained legacy tax schedule" do
      let!(:tax_configuration) { create(:tax_table, tax_year: 2026, pay_frequency: "biweekly", filing_status: "single") }

      it "uses its original legacy-engine tax frequency without inferring from current setup" do
        expect(source_item.tax_rule_snapshot).to include("engine" => "legacy_tax_table", "pay_frequency" => "biweekly")
        snapshot = source_item.calculation_context_snapshot.deep_dup
        snapshot.fetch("employee").delete("pay_frequency")
        source_item.update_columns(calculation_context_snapshot: snapshot)
        post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
        expect(response).to have_http_status(:ok), response.body
        expect(item.reload.gross_pay).to eq(2000)
      end
    end
  end

  context "a retained flat contractor fee" do
    let!(:employee) { create(:employee, :contractor, company: company, contractor_pay_type: "flat_fee", pay_rate: 500) }
    let!(:source_item) do
      original = create(:payroll_item, company: company, employee: employee, pay_period: source_period,
        employment_type: "contractor", pay_rate: 500, hours_worked: 0)
      PayrollCalculator.for(employee, original).calculate
      original.save!
      original
    end

    it "preserves the recorded fee despite a current amount edit" do
      employee.update!(pay_rate: 1500)
      post "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}/recalculate", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(item.reload.pay_rate).to eq(500)
      expect(item.gross_pay).to eq(500)
    end
  end
end
