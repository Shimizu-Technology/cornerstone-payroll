# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "demo:seed", :rls do
  let(:task) { Rake::Task["demo:seed"] }
  let!(:tax_tables) { %w[single married].map { |status| create(:tax_table, tax_year: 2026, filing_status: status) } }
  let!(:annual_config) do
    create(:annual_tax_config, tax_year: 2026, ss_wage_base: 184_500, ss_rate: 0.062, medicare_rate: 0.0145,
      additional_medicare_rate: 0.009, additional_medicare_threshold: 200_000, is_active: false).tap do |config|
      %w[single married].each do |status|
        filing = create(:filing_status_config, annual_tax_config: config, filing_status: status, standard_deduction: 0)
        create(:tax_bracket, filing_status_config: filing, bracket_order: 1, min_income: 0, max_income: nil, rate: 0.10)
      end
    end
  end
  let(:organization) { create(:organization, client_limit: 2) }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin") }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("demo:seed")
    task.reenable
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(Resend::Emails).to receive(:send).and_raise("The seed must not send email")
  end

  after { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  def run_task
    previous = ENV.to_h.slice("ORGANIZATION_ID", "ACTOR_ID")
    ENV["ORGANIZATION_ID"] = organization.id.to_s
    ENV["ACTOR_ID"] = admin.id.to_s
    begin
      task.invoke
    ensure
      %w[ORGANIZATION_ID ACTOR_ID].each { |key| ENV[key] = previous[key] }
    end
  end

  it "seeds under the RLS guard in raise mode, entering its own scopes without nesting" do
    expect(RlsContextGuard.mode).to eq("raise")
    expect { run_task }.to output(/OK    demo:seed .*periods_committed=16/).to_stdout
    TenantScope.as_system(reason: "Inspect the seeded demo employers") do
      expect(Company.demo.count).to eq(2)
      expect(HistoricalImportBatch.where(status: "locked").count).to eq(1)
    end

    task.reenable
    expect { run_task }.to output(/periods_committed=0 periods_skipped=16/).to_stdout
  end
end
