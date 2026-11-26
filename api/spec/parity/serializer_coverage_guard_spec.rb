# frozen_string_literal: true

require_relative "parity_helper"

module Parity
  # Manifest for the Track L serializer coverage guard (PLAN.md §13).
  # Every API v1 controller, presenter, or serializer referencing payroll money
  # figures (or delegating to a money-serializing presenter) must be mapped to a
  # real parity extractor class or explicitly documented as out-of-scope.
  module SerializerCoverageManifest
    SCAN_GLOBS = [
      "app/controllers/api/v1/**/*.rb",
      "app/services/**/*presenter*.rb",
      "app/services/**/*serializer*.rb",
      "app/serializers/**/*.rb"
    ].freeze

    MONEY_PATTERN = /\b(?:gross_pay|net_pay|withholding_tax|social_security_tax|medicare_tax|additional_withholding|additional_medicare_tax|retirement_payment|roth_retirement_payment|EmployeeStatements::Presenter|EmployeePayStatements::Presenter)\b/

    COVERED_SURFACES = {
      "app/controllers/api/v1/admin/checks_controller.rb" => "Parity::Extractors::StaffApiExtractor",
      "app/controllers/api/v1/admin/employees_controller.rb" => "Parity::Extractors::StaffApiExtractor",
      "app/controllers/api/v1/admin/pay_periods_controller.rb" => "Parity::Extractors::StaffApiExtractor",
      "app/controllers/api/v1/admin/reports_controller.rb" => "Parity::Extractors::StaffApiExtractor",
      "app/controllers/api/v1/client/employees_controller.rb" => "Parity::Extractors::ClientApiExtractor",
      "app/controllers/api/v1/client/pay_periods_controller.rb" => "Parity::Extractors::ClientApiExtractor",
      "app/controllers/api/v1/client/pay_stubs_controller.rb" => "Parity::Extractors::ClientApiExtractor",
      "app/controllers/api/v1/client/reports_controller.rb" => "Parity::Extractors::ClientApiExtractor",
      "app/controllers/api/v1/employee_portal/statements_controller.rb" => "Parity::Extractors::EmployeeApiExtractor",
      "app/controllers/api/v1/integrations/aire/worker_statements_controller.rb" => "Parity::Extractors::AireApiExtractor",
      "app/services/employee_statements/presenter.rb" => "Parity::Extractors::EmployeeApiExtractor",
      "app/services/employee_pay_statements/presenter.rb" => "Parity::Extractors::AireApiExtractor"
    }.freeze

    # Non-employee-statement or operational setup surfaces outside the
    # employee/client/staff paycheck parity boundary.
    EXEMPT_SURFACES = {
      "app/controllers/api/v1/admin/employee_bulk_imports_controller.rb" => "Admin employee bulk CSV import setup",
      "app/controllers/api/v1/admin/historical_imports_controller.rb" => "Admin historical import ingestion/preview",
      "app/controllers/api/v1/admin/non_employee_checks_controller.rb" => "Non-employee / FIT deposit vendor checks",
      "app/controllers/api/v1/admin/pay_stubs_controller.rb" => "Admin pay stub PDF wrapper (delegates to PayStubGenerator, covered via PayStubPdfExtractor)",
      "app/controllers/api/v1/admin/payroll_final_records_controller.rb" => "Final record export wrapper",
      "app/controllers/api/v1/admin/payroll_go_live_controller.rb" => "Go-live parallel comparison setup",
      "app/controllers/api/v1/admin/payroll_imports_controller.rb" => "Legacy MoSa payroll intake import",
      "app/controllers/api/v1/admin/payroll_intake_imports_controller.rb" => "Universal payroll intake import",
      "app/controllers/api/v1/admin/payroll_items_controller.rb" => "Draft/edit payroll item mutations (committed view covered via PayPeriodsController)",
      "app/controllers/api/v1/admin/prior_provider_histories_controller.rb" => "Prior-provider onboarding wizard",
      "app/controllers/api/v1/admin/timecards_controller.rb" => "Timecard OCR import preview"
    }.freeze
  end
end

RSpec.describe "Payroll money serializer coverage guard" do
  it "registers every API v1 controller, presenter, and serializer that emits payroll money figures" do
    root = Rails.root
    found = Parity::SerializerCoverageManifest::SCAN_GLOBS.flat_map { |glob| root.glob(glob) }.uniq.filter_map do |path|
      rel = path.relative_path_from(root).to_s
      rel if path.read.match?(Parity::SerializerCoverageManifest::MONEY_PATTERN)
    end.sort

    registered = (
      Parity::SerializerCoverageManifest::COVERED_SURFACES.keys +
      Parity::SerializerCoverageManifest::EXEMPT_SURFACES.keys
    ).sort
    unregistered = found - registered

    expect(unregistered).to be_empty,
      "New controller/presenter/serializer(s) referencing payroll money figures are not registered in the data parity suite:\n" \
      "#{unregistered.map { |f| "  - #{f}" }.join("\n")}\n" \
      "Add an extractor + parity spec coverage in spec/parity/ or document an explicit exemption in #{__FILE__}."
  end

  it "maps every covered surface to an existing parity extractor class" do
    Parity::SerializerCoverageManifest::COVERED_SURFACES.each do |rel_path, extractor_name|
      expect(Rails.root.join(rel_path)).to exist, "Missing covered surface file: #{rel_path}"
      extractor_class = Object.const_get(extractor_name)
      expect(extractor_class).to be_a(Class), "Expected #{extractor_name} for #{rel_path} to be a Class"
      expect(extractor_class.name).to start_with("Parity::Extractors::")
    end
  end

  it "does not retain stale paths in the parity manifest" do
    root = Rails.root
    all_paths = Parity::SerializerCoverageManifest::COVERED_SURFACES.keys +
      Parity::SerializerCoverageManifest::EXEMPT_SURFACES.keys
    missing = all_paths.reject { |rel| root.join(rel).exist? }
    expect(missing).to be_empty, "Stale parity manifest entries: #{missing.inspect}"
  end
end
