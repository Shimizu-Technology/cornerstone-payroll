# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe "quickbooks_history:import" do
  let!(:company) { create(:company) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:task) { Rake::Task["quickbooks_history:import"] }
  let(:bundle_dir) { Dir.mktmpdir("quickbooks-history-rake") }
  let(:managed_env_keys) { %w[BUNDLE_DIR COMPANY_ID ACTOR_EMAIL APPLY LOCK] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("quickbooks_history:import")
    task.reenable
    @previous_env = managed_env_keys.index_with { |key| ENV[key] }
    managed_env_keys.each { |key| ENV.delete(key) }
    ENV["BUNDLE_DIR"] = bundle_dir
    ENV["COMPANY_ID"] = company.id.to_s
  end

  after do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(bundle_dir) if File.exist?(bundle_dir)
  end

  it "requires an attributed operator even for preview-only runs" do
    expect { task.invoke }.to raise_error(KeyError, /ACTOR_EMAIL/)
  end

  it "rejects an accountant before reading or staging source files" do
    ENV["ACTOR_EMAIL"] = accountant.email
    expect(QuickbooksHistory::BundleParser).not_to receive(:new)

    expect do
      task.invoke
    end.to raise_error(ArgumentError, /manager or administrator with access/)
    expect(HistoricalImportBatch.count).to eq(0)
  end
end
