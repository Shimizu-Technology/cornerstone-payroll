# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "FICA release-day runner with the tenant guard on", :rls do
  let(:runner) { Rails.root.join("..", "ops", "payroll-release-day", "release_day.rb") }
  let(:connection) { ApplicationRecord.connection }

  around do |example|
    previous_rake = Rake.application
    Rake.application = Rake::Application.new
    example.run
  ensure
    Rake.application = previous_rake
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    # The runner opens real repeatable-read snapshots in production. The
    # spec already has a transaction so its synthetic fixtures roll back.
    allow(connection).to receive(:transaction).and_call_original
    allow(connection).to receive(:transaction).with(isolation: :repeatable_read).and_yield
    allow(connection).to receive(:execute).and_call_original
    allow(connection).to receive(:execute).with("SET TRANSACTION READ ONLY").and_return(nil)

    TenantScope.as_system(reason: "Build synthetic release-runner fixtures") do
      create(:tax_table)
      @company = create(:company, name: "Selected Synthetic Employer", auto_create_fit_check: false)
      @other_company = create(:company, name: "Other Synthetic Employer", auto_create_fit_check: false)
      @actor = create(:user, company: @company, role: "admin")
      @selected_item = legacy_paycheck(@company)
      legacy_paycheck(@other_company)
    end
  end

  def legacy_paycheck(company)
    employee = create(:employee, company: company, department: create(:department, company: company), pay_rate: 15)
    period = create(:pay_period, company: company, status: "committed")
    item = period.payroll_items.build(company: company, employee: employee, employment_type: "hourly",
      pay_rate: 15, hours_worked: 0, bonus: 1000)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    item.update_columns(social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      additional_medicare_taxable_wages: nil, additional_medicare_tax: nil,
      medicare_taxable_wages: nil, cash_tips_reported: nil, tax_rule_snapshot: {})
    item
  end

  def run_release(mode, digest: nil)
    config = {
      "DEPLOYMENT_ENV" => "test", "EXPECTED_DEPLOYMENT_ENV" => "test",
      "RENDER_SERVICE_ID" => "synthetic", "EXPECTED_SERVICE_ID" => "synthetic",
      "RENDER_GIT_COMMIT" => "synthetic", "EXPECTED_COMMIT" => "synthetic",
      "DATABASE_URL" => "postgresql://localhost/synthetic", "EXPECTED_DB_HOST" => "localhost",
      "TAX_YEAR" => "2024", "THROUGH_PAY_DATE" => "2024-12-31",
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
    expect { load runner, true }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(0) }
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
    expect(proof_item_ids).to eq([ @selected_item.id ])
  end
end
