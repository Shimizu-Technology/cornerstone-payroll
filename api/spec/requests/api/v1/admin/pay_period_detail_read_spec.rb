# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pay period detail read", type: :request do
  let(:company) { detail_read_context[:company] }
  let(:user) { detail_read_context[:actor] }

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(user)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(user.id)
  end

  def detail(period)
    get "/api/v1/admin/pay_periods/#{period.id}"
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def query_count(period)
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/)

      count += 1
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { detail(period) }
    count
  end

  # Without the shared lookup every row asks its own single-row questions, which
  # is the unbatched read. Batching must not change one byte of the answer.
  def unbatched_detail(period)
    allow(PayrollPaymentEligibilityLookup).to receive(:new).and_return(nil)
    detail(period)
  ensure
    allow(PayrollPaymentEligibilityLookup).to receive(:new).and_call_original
  end

  describe "query count" do
    it "does not grow with payroll rows or source lines on a committed run" do
      small = build_detail_read_period(ordinary_rows: 16, branches: false)
      large = build_detail_read_period(ordinary_rows: 48, branches: false)
      detail(small)

      small_count = query_count(small)
      large_count = query_count(large)

      expect(large.payroll_items.count).to eq(small.payroll_items.count * 3)
      expect(large_count - small_count).to be <= 2
      expect(large_count).to be <= 60
    end

    it "does not grow with payroll rows on a draft run" do
      small = build_detail_read_period(ordinary_rows: 8, status: :draft, branches: false)
      large = build_detail_read_period(ordinary_rows: 24, status: :draft, branches: false)
      detail(small)

      expect(query_count(large) - query_count(small)).to be <= 2
    end

    it "stays bounded when every eligibility branch is present" do
      period = build_detail_read_period(ordinary_rows: 4)

      expect(query_count(period)).to be <= 65
    end

    it "does not ask for evidence a draft run never reaches" do
      period = build_detail_read_period(ordinary_rows: 4, status: :draft, branches: false)
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { detail(period) }

      expect(queries.grep(/time_tracking_financial_correction_links|time_tracking_correction_dispositions" WHERE "time_tracking_correction_dispositions"\."corrective/)).to be_empty
    end
  end

  describe "response" do
    it "matches the unbatched read for every committed eligibility outcome" do
      period = build_detail_read_period(ordinary_rows: 4)

      batched = detail(period)

      expect(batched).to eq(unbatched_detail(period))
      outcomes = batched.dig("pay_period", "payroll_items").map { |row| row["payment_method_change"] }
      expect(outcomes.map { |outcome| outcome["mode"] }.uniq).to contain_exactly("simple", "retire_check", "blocked")
      expect(outcomes.filter_map { |outcome| outcome["reason"]&.slice(0, 30) }.uniq).to contain_exactly(
        "A bank payment has already bee", "Cancel or recover the original", "Finish syncing the earlier che",
        "Reconcile the saved reported-p", "The connected time source must", "The original check's exact sou",
        "There is no net payment to cha", "This check has cleared. Resolv", "This payment has an exact sour",
        "This payment is linked to a du", "This payment is voided. Its de", "Verify the connected employee "
      )
      expect(batched.dig("pay_period", "payroll_items").map { |row| row["earnings_statement_eligible"] }.uniq).to contain_exactly(true, false)
      expect(batched.dig("pay_period", "payroll_items").filter_map { |row| row["correction_pay_basis_hold"] }).not_to be_empty
    end

    it "matches the unbatched read for draft pay-basis holds" do
      period = build_detail_read_period(ordinary_rows: 2, status: :draft)

      batched = detail(period)

      expect(batched).to eq(unbatched_detail(period))
      holds = batched.dig("pay_period", "payroll_items").filter_map { |row| row.dig("correction_pay_basis_hold", "reason") }
      expect(holds).to include(TimeTracking::SourceEarningsConservation::PAY_BASIS_MESSAGE, /original pay basis is unavailable/)
      reasons = batched.dig("pay_period", "payroll_items").filter_map { |row| row.dig("payment_method_change", "reason") }
      expect(reasons).to include(/Remove the draft check number/, /Reconcile the saved reported-payment match/)
    end

    it "keeps retained empty rows out of the rows and the totals" do
      period = build_detail_read_period(ordinary_rows: 2)
      body = detail(period).fetch("pay_period")

      retained = period.payroll_items.joins(:legacy_disposition).pluck(:id)
      expect(retained.size).to eq(1)
      expect(body.fetch("payroll_items").map { |row| row["id"] }).not_to include(retained.first)
      expect(body.fetch("employee_count")).to eq(period.payroll_items.financially_reportable.reportable.count)
    end
  end
end
