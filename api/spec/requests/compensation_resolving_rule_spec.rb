# frozen_string_literal: true

require "rails_helper"

# M3-4 invariant 5: every open payroll reader resolves pay rates on the pay
# period end date. A raise scheduled for Dec 1 must leave the open Nov 16-30
# period at the old rate and reach the Dec 1-15 period, whichever path fills
# the paycheck.
RSpec.describe "Pay rates resolve on the pay period end date", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.parse("2026-11-20 12:00:00 +10:00")) { example.run } }

  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:employee) { create(:employee, company: company, pay_rate: 15, hire_date: Date.new(2026, 1, 1)) }
  let!(:regular) { employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true) }
  let!(:weekend) { employee.employee_wage_rates.create!(label: "Weekend", rate: 20) }
  let!(:open_period) { create(:pay_period, company: company, start_date: Date.new(2026, 11, 16), end_date: Date.new(2026, 11, 30), pay_date: Date.new(2026, 12, 4)) }
  let!(:next_period) { create(:pay_period, company: company, start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 15), pay_date: Date.new(2026, 12, 19)) }

  before do
    ensure_verified_test_tax_years(2026)
    EmployeeCompensationChangeService.new(
      employee: employee, actor: actor, source: "staff", reason: "Annual raise", effective_on: "2026-12-01",
      pay_rate: 17, wage_rate_edits: [ { id: regular.id, rate: 17 } ]
    ).call!
    employee.reload
  end

  def rates_by_label(rates)
    rates.to_h { |rate| [ rate.label, rate.rate.to_d ] }
  end

  it "resolves from history while the cache still holds today's rate" do
    expect(employee.pay_rate).to eq(15)
    expect(rates_by_label(employee.wage_rates_on(open_period.end_date))).to eq("Regular" => 15, "Weekend" => 20)
    expect(rates_by_label(employee.wage_rates_on(next_period.end_date))).to eq("Regular" => 17, "Weekend" => 20)
  end

  it "calculates the open pay run at the old rate and the next one at the new rate" do
    controller = Api::V1::Admin::PayPeriodsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)

    [ [ open_period, 15 ], [ next_period, 17 ] ].each do |period, expected|
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: { employee_ids: [ employee.id ], hours: { employee.id.to_s => { regular: 80 } } }, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(period.payroll_items.find_by!(employee: employee).pay_rate).to eq(expected)
    end
  end

  it "gives the pay-run worksheet the rates of its pay period" do
    controller = Api::V1::Admin::EmployeesController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)

    get "/api/v1/admin/employees", params: { eligible_pay_period_id: open_period.id }
    row = response.parsed_body.fetch("data").find { |data| data["id"] == employee.id }
    expect(row.fetch("wage_rates").map { |rate| [ rate["label"], rate["rate"].to_d ] }).to contain_exactly([ "Regular", 15 ], [ "Weekend", 20 ])

    get "/api/v1/admin/employees", params: { eligible_pay_period_id: next_period.id }
    row = response.parsed_body.fetch("data").find { |data| data["id"] == employee.id }
    expect(row.fetch("pay_rate").to_d).to eq(17)
    expect(row.fetch("wage_rates").map { |rate| [ rate["label"], rate["rate"].to_d ] }).to contain_exactly([ "Regular", 17 ], [ "Weekend", 20 ])
  end

  it "uses the period's rates for the MoSa Revel import" do
    [ [ open_period, 15 ], [ next_period, 17 ] ].each do |period, expected|
      choice = PayrollImport::WageRateChoice.new(employee: employee, pay_period: period).preview
      expect(choice.fetch(:wage_rate_options).to_h { |option| [ option[:label], option[:rate] ] }).to eq("Regular" => expected.to_f, "Weekend" => 20.0)

      item = period.payroll_items.new(employee: employee, company: company)
      PayrollImport::ImportService.new(period, actor: actor).send(:apply_employment!, item, employee)
      expect(item.pay_rate).to eq(expected)
    end
  end

  it "uses the period's rate for the Spike intake" do
    [ [ open_period, 15 ], [ next_period, 17 ] ].each do |period, expected|
      service = PayrollIntake::ApplyService.allocate
      service.instance_variable_set(:@pay_period, period)
      service.instance_variable_set(:@company, company)
      item = period.payroll_items.new(employee: employee)
      service.send(:prepare_payroll_item_for_intake!, item, employee)
      expect(item.pay_rate).to eq(expected)
    end
  end

  it "shows client standing changes and expected entries at the period's job rate" do
    standing = PayrollStandingChange.create!(company: company, employee: employee, employee_wage_rate: regular, kind: "extra_hours", position: 1)
    expect(PayrollSubmissions::StandingChanges.new(company: company, before_pay_date: nil, rates_on: open_period.end_date).rows.sole)
      .to include(standing_change_id: standing.id, wage_rate: "15.0")
    expect(PayrollSubmissions::StandingChanges.new(company: company, before_pay_date: nil, rates_on: next_period.end_date).rows.sole)
      .to include(wage_rate: "17.0")
    expect(PayrollExpectedEntries.new(open_period).payload.fetch(:fields).sole.fetch(:wage_rate)).to eq(15)
    expect(PayrollExpectedEntries.new(next_period).payload.fetch(:fields).sole.fetch(:wage_rate)).to eq(17)
  end

  it "applies timecard hours at the period's job rate" do
    [ [ open_period, 15 ], [ next_period, 17 ] ].each do |period, expected|
      controller = Api::V1::Admin::TimecardsController.new
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(wage_rate_id: regular.id))
      item = period.payroll_items.new(employee: employee, company: company)
      expect(controller.send(:apply_timecard_hours_to_payroll_item, item, employee, 8)).to be_nil
      expect(item.wage_rate_hours.find { |entry| entry["label"] == "Regular" }["rate"].to_d).to eq(expected)
    end
  end

  it "prices AIRE batch categories at the period's job rate" do
    source = create(:time_tracking_source, company: company)
    [ [ open_period, 1500 ], [ next_period, 1700 ] ].each do |period, cents|
      match = TimeTracking::BatchImportPreviewService.new(pay_period: period, source: source)
        .send(:match_wage_rate_buckets, [ { key: "regular", name: "Regular", total_hours: 8 } ], employee.id)
      expect(match[:categories].sole).to include(wage_rate_label: "Regular", payroll_rate_cents: cents)
    end
  end

  it "shows the rate in effect at the end of a pay history report range" do
    controller = Api::V1::Admin::ReportsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)

    get "/api/v1/admin/reports/employee_pay_history", params: { employee_id: employee.id, start_date: "2026-11-01", end_date: "2026-11-30" }
    expect(response.parsed_body.dig("report", "employee", "pay_rate")).to eq(15.0)
  end

  it "warns on an open period that a change starts in the middle of" do
    EmployeeCompensationChangeService.new(
      employee: employee, actor: actor, source: "staff", reason: "Promotion", effective_on: "2026-11-23", pay_rate: 16
    ).call!
    create(:payroll_item, company: company, pay_period: open_period, employee: employee, pay_rate: 16)
    expect(open_period.mid_period_compensation_warnings.join).to include("pay rate changes mid-period on 2026-11-23")
    expect(next_period.mid_period_compensation_warnings.join).not_to include("mid-period")
  end
  def commit_money!(period, expected, before_commit: nil)
    employee_ids = expected.keys
    items = period.payroll_items.where(employee_id: employee_ids).index_by(&:employee_id)
    actual = -> { items.transform_values { |item| item.reload.attributes.values_at("gross_pay", "net_pay") } }
    expect(actual.call).to eq(expected)
    lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
    lifecycle.approve!
    before_commit&.call
    lifecycle.commit!
    expect(period.reload).to be_committed
    expect(actual.call).to eq(expected)
  end

  def run_manual!(period, employee_ids, hours)
    controller = Api::V1::Admin::PayPeriodsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    allow_any_instance_of(controller).to receive(:current_user_id).and_return(actor.id)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
      params: { employee_ids: employee_ids, hours: hours }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("results", "errors")).to be_empty
  end

  it "calculates, approves and commits manual multirate and salary pay before and after the raise" do
    salary = create(:employee, :salary, company: company, pay_rate: 31_200)
    EmployeeCompensationChangeService.new(employee: salary, actor: actor, source: "staff",
      effective_on: "2026-12-01", pay_rate: 35_360).call!
    hours = { employee.id.to_s => { wage_rates: [
      { employee_wage_rate_id: regular.id, label: "Client-submitted label", rate: 99, regular_hours: 80 }
    ] } }
    [ [ open_period, 1200, "1040.56" ], [ next_period, 1360, "1169.12" ] ].each do |period, gross, net|
      run_manual!(period, [ employee.id, salary.id ], hours)
      expect(period.payroll_items.find_by!(employee: employee).wage_rate_hours.sole).to include("label" => "Regular", "rate" => gross / 80)
      commit_money!(period, { employee.id => [ gross, net.to_d ], salary.id => [ gross, net.to_d ] })
    end
  end

  it "reprices saved ordinary job buckets when a single item is recalculated" do
    controller = Api::V1::Admin::PayrollItemsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    item = create(:payroll_item, company: company, employee: employee, pay_period: next_period,
      pay_rate: 15, hours_worked: 80, wage_rate_hours: [
        { employee_wage_rate_id: regular.id, label: "Regular", rate: 15, regular_hours: 80, active: true, is_primary: true }
      ])
    item.calculate!
    expect(item.reload.gross_pay).to eq(1200)

    post "/api/v1/admin/pay_periods/#{next_period.id}/payroll_items/#{item.id}/recalculate", as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(item.reload.attributes.values_at("gross_pay", "net_pay")).to eq([ 1360, "1169.12".to_d ])
    expect(item.wage_rate_hours.sole["rate"]).to eq(17)
  end

  it "keeps older manual gross, net and basis after a conversion, including a committed PDF after correction" do
    EmployeeCompensationChangeService.new(employee: employee, actor: actor, source: "staff",
      effective_on: "2026-12-01", reason: "Raise withdrawn", cancel: true).call!
    change_wage_rate!(regular, effective_on: "2026-11-23", rate: 16)
    run_manual!(open_period, [ employee.id ], { employee.id.to_s => { regular: 80 } })
    expect(open_period.mid_period_compensation_warnings.sole).to include("mid-period on 2026-11-23")
    expect(open_period.payroll_items.find_by!(employee: employee).attributes.values_at("gross_pay", "net_pay")).to eq([ 1280, "1104.84".to_d ])
    allow(PayrollBusinessClock).to receive(:today).and_return(Date.new(2026, 12, 1))
    aggregate_failures do
      change_compensation!(employee, effective_on: "2026-12-01", employment_type: "salary", salary_type: "annual",
        pay_rate: 52_000, pay_frequency: "semimonthly")
      run_manual!(open_period, [ employee.id ], { employee.id.to_s => { regular: 80 } })
      item = open_period.payroll_items.find_by!(employee: employee)
      expect(item.calculation_context_snapshot.fetch("employee")).to include("employment_type" => "hourly", "pay_frequency" => "biweekly")
      commit_money!(open_period, { employee.id => [ 1280, "1104.84".to_d ] })
      pdf = PayStubGenerator.new(item.reload).generate
      EmployeeCompensationChangeService.new(employee: employee, actor: actor, source: "staff",
        effective_on: "2026-11-25", pay_rate: 21, historical_correction: true, reason: "Reconcile historical scalar rate").call!
      SyncEffectiveCompensationJob.perform_now
      expect(item.reload.attributes.values_at("gross_pay", "net_pay")).to eq([ 1280, "1104.84".to_d ])
      expect(PayStubGenerator.new(item).generate).to eq(pdf)
    end
  end

  it "applies and commits MoSa Revel hours with the reviewed dated job in both periods" do
    [ [ open_period, 1200, "1040.56" ], [ next_period, 1360, "1169.12" ] ].each do |period, gross, net|
      service = PayrollImport::ImportService.new(period, actor: actor)
      pdf = build_revel_pdf([ { name: "#{employee.last_name}, #{employee.first_name}", regular_hours: 80, regular_pay: 6_000 } ],
        period_start: period.start_date, period_end: period.end_date)
      preview = File.open(pdf, "rb") { |file| service.preview(pdf_file: file, excel_records: []) }
      row = preview.fetch(:matched).sole
      expect(service.apply!(matched: [ row.merge(selected_wage_rate_id: regular.id) ]).fetch(:errors)).to be_empty
      commit_money!(period, { employee.id => [ gross, net.to_d ] })
    end
  end

  it "applies Spike email intake and commits across cache activation with an intake exception" do
    company.update!(payroll_intake_source_types: [ "spike_email" ])
    open_period.update!(start_date: "2026-11-15", end_date: "2026-11-28")
    next_period.update!(start_date: "2026-11-29", end_date: "2026-12-12")
    EmployeeW4ElectionChangeService.new(employee: employee, actor: actor, source: "staff", reason: "Synthetic withholding review",
      attributes: { w4_effective_on: open_period.start_date, filing_status: "single", w4_form_version: 2020 }).call!
    employee.update_columns(intake_exception: { "reason" => "Deferred intake field" },
      intake_payroll_confirmed_at: Time.current, intake_payroll_eligible_from: open_period.start_date)
    workweek = CompanyWorkweek.create!(company: company, effective_on: Date.new(2026, 1, 1),
      starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
      confirmation_status: "confirmed", source: "operator_confirmed", confirmed_by: actor, confirmed_at: Time.current, notes: "Verified fictional workweek")
    [ [ open_period, 1200, "1040.56" ], [ next_period, 1360, "1169.12" ] ].each do |period, gross, net|
      period.update!(company_workweek: workweek)
      pasted_text = <<~EMAIL
        Spike payroll for #{period.start_date.strftime('%m/%d/%Y')} - #{period.end_date.strftime('%m/%d/%Y')}
        Employee,Week 1 Hours,Week 2 Hours,Week 1 Tips,Week 2 Tips
        #{employee.full_name},40,40,0,0
      EMAIL
      session = PayrollIntake::PreviewService.new(pay_period: period, source_type: "spike_email", actor: actor,
        pasted_text: pasted_text).call.fetch(:session)
      row = session.rows.sole
      result = PayrollIntake::ApplyService.new(session: session, actor: actor, acknowledge_warnings: true,
        row_overrides: [ { id: row.id, employee_id: employee.id, disposition: "included" } ]).call
      expect(result.fetch(:errors)).to be_empty
      commit_money!(period, { employee.id => [ gross, net.to_d ] }, before_commit: -> { SyncEffectiveCompensationJob.perform_now(as_of: "2026-12-01") })
    end
  end
end
