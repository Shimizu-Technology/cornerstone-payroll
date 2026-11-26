# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "FICA release-day runner with forced RLS", :rls do
  include EnforcedRlsHelpers
  include FicaHistoryHelpers

  self.use_transactional_tests = false

  let(:runner) { Rails.root.join("..", "ops", "payroll-release-day", "release_day.rb") }
  let(:connection) { ApplicationRecord.connection }

  around do |example|
    previous_rake = Rake.application
    Rake.application = Rake::Application.new
    connection.transaction(isolation: :repeatable_read) do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    Rake.application = previous_rake
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    # Fixtures and forced policies live in the outer repeatable-read transaction.
    # Use a real savepoint for each runner snapshot and roll it back to restore write access.
    allow(connection).to receive(:transaction).and_call_original
    allow(connection).to receive(:transaction).with(isolation: :repeatable_read).and_wrap_original do |transaction, &snapshot|
      result = nil
      transaction.call(requires_new: true) do
        result = snapshot.call
        expect(connection.select_value("SHOW transaction_isolation")).to eq("repeatable read")
        expect(connection.select_value("SHOW transaction_read_only")).to eq("on")
        raise ActiveRecord::Rollback
      end
      result
    end
  end

  def prepare_fixtures
    fixtures = TenantScope.as_system(reason: "Build synthetic release-runner fixtures") do
      create(:tax_table, tax_year: 2026, ss_wage_base: 184_500)
      @company = create(:company, name: "Selected Synthetic Employer", auto_create_fit_check: false)
      @other_company = create(:company, name: "Other Synthetic Employer", auto_create_fit_check: false)
      @actor = create(:user, company: @company, role: "admin")

      [ @company, @other_company ].map { |company| yield company }
    end
    enforce_as_runtime_role!
    fixtures
  end

  def employee_for(company)
    create(:employee, company: company, department: create(:department, company: company), pay_rate: 15)
  end

  def legacy_paycheck(employee, voided: false)
    company = employee.company
    period = create(:pay_period, company: company, status: "committed",
      start_date: "2026-02-01", end_date: "2026-02-14", pay_date: "2026-02-20")
    item = create(:payroll_item, company: company, employee: employee, pay_period: period, hours_worked: 0,
      gross_pay: 1000, net_pay: "923.50", social_security_tax: 62, employer_social_security_tax: 62,
      medicare_tax: "14.50", employer_medicare_tax: "14.50", additional_medicare_tax: 0)
    period.update_columns(correction_status: "voided") if voided
    item
  end

  def imported_paycheck(company)
    employee = employee_for(company)
    # Void history keeps this employee-year in the runner's review scope.
    legacy_paycheck(employee, voided: true)
    batch = create(:historical_import_batch, company: company, status: "locked", locked_at: Time.current)
    source_actor = company == @company ? @actor : create(:user, company: company, role: "admin")
    EmployeeYearFicaSourceReview.record!(employee: employee, actor: source_actor, tax_year: 2026, through_pay_date: "2026-12-31",
      external_ss_wage_bound: 0, external_medicare_wage_bound: 0, review_reference: "Synthetic imported wage source review")
    imported(employee, company: company, batch: batch, tips: 100)
  end

  def run_release(mode, digest: nil, expected_status: 0)
    config = {
      "DEPLOYMENT_ENV" => "test", "EXPECTED_DEPLOYMENT_ENV" => "test",
      "RENDER_SERVICE_ID" => "synthetic", "EXPECTED_SERVICE_ID" => "synthetic",
      "RENDER_GIT_COMMIT" => "synthetic", "EXPECTED_COMMIT" => "synthetic",
      "DATABASE_URL" => "postgresql://localhost/synthetic", "EXPECTED_DB_HOST" => "localhost",
      "TAX_YEAR" => "2026", "THROUGH_PAY_DATE" => "2026-12-31",
      "COMPANY_IDS" => @company.id.to_s, "ACTOR_ID" => @actor.id.to_s,
      "REVIEW_REFERENCE" => "Synthetic full-year payroll evidence",
      "CONFIRM_NO_OUTSIDE_WAGES" => "1", "EXTERNAL_SS_WAGE_BOUND" => "0",
      "EXTERNAL_MEDICARE_WAGE_BOUND" => "0", "RELEASE_MODE" => mode,
      "RELEASE_APPLY" => (mode == "apply" ? "1" : nil), "PREVIEW_DIGEST" => digest
    }
    saved_config = config.keys.index_with { |key| ENV[key] }
    previous_logger_level = Rails.logger.level
    previous_stdout = $stdout
    $stdout = output = StringIO.new
    config.each { |key, value| ENV[key] = value }
    expect { load runner, true }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(expected_status) }
    output.string.lines.map { |line| JSON.parse(line) }
  ensure
    $stdout = previous_stdout
    Rails.logger.level = previous_logger_level
    saved_config.each { |key, value| ENV[key] = value }
  end

  def proof_item_ids
    TenantScope.as_system(reason: "Check which synthetic paychecks received proof") do
      PayrollItemFicaBasisProof.pluck(:payroll_item_id)
    end
  end

  it "previews both companies and applies only to the selected company" do
    selected_item, = prepare_fixtures { |company| legacy_paycheck(employee_for(company)) }
    TenantScope.with_company(@company.id) do
      expect(PayrollItem.pluck(:id)).to eq([ selected_item.id ])
    end

    preview = run_release("preview")
    expect(preview.select { |event| event["event"] == "before_inventory" }).to contain_exactly(
      a_hash_including("company_id" => @company.id, "selected" => true, "employee_years" => 1),
      a_hash_including("company_id" => @other_company.id, "selected" => false, "employee_years" => 1)
    )
    expect(preview.select { |event| event["event"] == "imported_fica_plan" }).to contain_exactly(
      a_hash_including("company_id" => @company.id)
    )
    expect(proof_item_ids).to be_empty
    digest = preview.find { |event| event["event"] == "preview_manifest" }.fetch("digest")

    applied = run_release("apply", digest: digest)
    expect(applied).to include(a_hash_including("event" => "recover_receipt", "company_id" => @company.id, "applied_proofs" => 1))
    expect(applied).to include(a_hash_including("event" => "finished", "mode" => "apply"))
    expect(proof_item_ids).to eq([ selected_item.id ])
  end

  it "records a source review only for the selected company's held employee-year" do
    selected_employee, = prepare_fixtures do |company|
      employee = employee_for(company)
      legacy_paycheck(employee, voided: true)
      legacy_paycheck(employee)
      employee
    end

    preview = run_release("preview", expected_status: 3)
    expect(preview.select { |event| event["event"] == "before_inventory" }).to contain_exactly(
      a_hash_including("company_id" => @company.id, "employee_year_counts" => { "held" => 1 }),
      a_hash_including("company_id" => @other_company.id, "employee_year_counts" => { "held" => 1 })
    )
    expect(preview.select { |event| event["event"] == "source_review_plan" }).to contain_exactly(
      a_hash_including("company_id" => @company.id, "employee_years" => 1)
    )
    digest = preview.find { |event| event["event"] == "preview_manifest" }.fetch("digest")

    TenantScope.as_system(reason: "Check preview left source reviews unwritten") do
      expect(EmployeeYearFicaSourceReview.all).to be_empty
    end

    applied = run_release("apply", digest: digest)
    expect(applied).to include(a_hash_including("event" => "source_review_receipt", "company_id" => @company.id, "applied_reviews" => 1))
    expect(applied).to include(a_hash_including("event" => "finished", "mode" => "apply"))
    TenantScope.as_system(reason: "Verify source reviews across both synthetic employers") do
      expect(EmployeeYearFicaSourceReview.sole).to have_attributes(company_id: @company.id, employee_id: selected_employee.id,
        created_by_id: @actor.id, tax_year: 2026, through_pay_date: Date.new(2026, 12, 31),
        external_ss_wage_bound: 0, external_medicare_wage_bound: 0)
    end
  end

  it "creates an imported FICA proof only for the selected company's recoverable paycheck" do
    selected_paycheck, other_paycheck = prepare_fixtures { |company| imported_paycheck(company) }
    TenantScope.with_company(@other_company.id) do
      inventory = ImportedPaycheckFicaReconciliation.new(company: @other_company, year: 2026).inventory
      expect(inventory[:employee_years].sole[:rows].sole).to include(
        historical_paycheck_id: other_paycheck.id, status: "recoverable")
    end

    preview = run_release("preview")
    expect(preview.select { |event| event["event"] == "imported_fica_review" }).to contain_exactly(
      a_hash_including("company_id" => @company.id, "counts" => { "proven" => 0, "recoverable" => 1, "held" => 0 })
    )
    digest = preview.find { |event| event["event"] == "preview_manifest" }.fetch("digest")

    TenantScope.as_system(reason: "Check preview left imported proofs unwritten") do
      expect(HistoricalPaycheckFicaBasisProof.all).to be_empty
    end

    applied = run_release("apply", digest: digest)
    expect(applied).to include(a_hash_including("event" => "imported_fica_receipt", "company_id" => @company.id, "applied_proofs" => 1))
    expect(applied).to include(a_hash_including("event" => "finished", "mode" => "apply"))
    TenantScope.as_system(reason: "Verify imported FICA proofs across both synthetic employers") do
      proof = HistoricalPaycheckFicaBasisProof.sole
      expect(proof).to have_attributes(company_id: @company.id, historical_paycheck_id: selected_paycheck.id,
        created_by_id: @actor.id, tax_year: 2026)
      expect(proof.evidence.fetch("bases")).to include("social_security_taxable_wages" => "900.0", "social_security_taxable_tips" => "100.0")
    end
  end
end
