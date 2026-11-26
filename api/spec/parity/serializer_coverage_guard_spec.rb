# frozen_string_literal: true

require_relative "parity_helper"

# Guard spec (PLAN.md §13 Track L): fails whenever a new API v1 controller
# serializes payroll money figures (`gross_pay`, `net_pay`, `withholding_tax`)
# without being registered in the parity suite manifest — either covered by an
# extractor or explicitly categorized as out-of-scope (e.g. non-employee checks,
# import setup, or pre-commit intake).
RSpec.describe "Payroll money serializer coverage guard" do
  MONEY_PATTERN = /\b(?:gross_pay|net_pay|withholding_tax)\b/

  COVERED_CONTROLLERS = %w[
    app/controllers/api/v1/admin/checks_controller.rb
    app/controllers/api/v1/admin/pay_periods_controller.rb
    app/controllers/api/v1/admin/reports_controller.rb
    app/controllers/api/v1/client/pay_periods_controller.rb
    app/controllers/api/v1/client/pay_stubs_controller.rb
    app/controllers/api/v1/client/reports_controller.rb
  ].freeze

  # Non-employee-statement or operational setup controllers that reference money
  # fields outside the employee/client/staff paycheck parity boundary.
  EXEMPT_CONTROLLERS = {
    "app/controllers/api/v1/admin/historical_imports_controller.rb" => "Admin historical import ingestion/preview",
    "app/controllers/api/v1/admin/non_employee_checks_controller.rb" => "Non-employee / FIT deposit vendor checks",
    "app/controllers/api/v1/admin/pay_stubs_controller.rb" => "Admin pay stub PDF wrapper (delegates to PayStubGenerator, covered via PDF extractor)",
    "app/controllers/api/v1/admin/payroll_final_records_controller.rb" => "Final record export wrapper",
    "app/controllers/api/v1/admin/payroll_go_live_controller.rb" => "Go-live parallel comparison setup",
    "app/controllers/api/v1/admin/payroll_imports_controller.rb" => "Legacy MoSa payroll intake import",
    "app/controllers/api/v1/admin/payroll_intake_imports_controller.rb" => "Universal payroll intake import",
    "app/controllers/api/v1/admin/payroll_items_controller.rb" => "Draft/edit payroll item mutations (committed view covered via PayPeriodsController)",
    "app/controllers/api/v1/admin/prior_provider_histories_controller.rb" => "Prior-provider onboarding wizard",
    "app/controllers/api/v1/admin/timecards_controller.rb" => "Timecard OCR import preview"
  }.freeze

  it "registers every API v1 controller that serializes payroll money figures" do
    root = Rails.root
    found = root.glob("app/controllers/api/v1/**/*.rb").filter_map do |path|
      rel = path.relative_path_from(root).to_s
      rel if path.read.match?(MONEY_PATTERN)
    end.sort

    registered = (COVERED_CONTROLLERS + EXEMPT_CONTROLLERS.keys).sort
    unregistered = found - registered

    expect(unregistered).to be_empty,
      "New controller(s) referencing payroll money figures are not registered in the data parity suite:\n" \
      "#{unregistered.map { |f| "  - #{f}" }.join("\n")}\n" \
      "Add an extractor + parity spec coverage in spec/parity/ or document an explicit exemption in #{__FILE__}."
  end

  it "does not retain stale controller paths in the parity manifest" do
    root = Rails.root
    missing = (COVERED_CONTROLLERS + EXEMPT_CONTROLLERS.keys).reject { |rel| root.join(rel).exist? }
    expect(missing).to be_empty, "Stale parity manifest entries: #{missing.inspect}"
  end
end
