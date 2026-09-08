# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalPayrollImports::Registry do
  subject(:registry) { described_class.default }

  it "publishes the complete QuickBooks Online migration contract" do
    contract = registry.contracts.sole

    expect(contract).to include(
      key: "quickbooks_online",
      label: "QuickBooks Online Payroll",
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION,
      accepted_extensions: QuickbooksHistory::BundleParser::ALLOWED_EXTENSIONS,
      max_files: QuickbooksHistory::BundleParser::MAX_FILE_COUNT
    )
    expect(contract.fetch(:capabilities)).to eq(
      source_file_retention: true,
      cutover_verification: true,
      client_bootstrap: true,
      ytd_bridge: true
    )
    expect(contract.fetch(:limitations)).not_to be_empty
  end

  it "fails closed for an unregistered payroll source" do
    expect { registry.fetch!("unsupported_payroll") }
      .to raise_error(ArgumentError, "Unsupported historical payroll source: unsupported_payroll")
  end

  it "rejects duplicate adapter keys" do
    adapter = HistoricalPayrollImports::QuickbooksOnlineAdapter.new

    expect { described_class.new(adapters: [ adapter, adapter ]) }
      .to raise_error(ArgumentError, /keys must be unique/)
  end

  it "requires the source-retention and cutover safety capabilities" do
    adapter = Class.new(HistoricalPayrollImports::QuickbooksOnlineAdapter) do
      def capabilities = super.merge(cutover_verification: false)
    end.new

    expect { described_class.new(adapters: [ adapter ]) }
      .to raise_error(ArgumentError, /retain source files and support cutover verification/)
  end

  it "lets orchestration use an injected adapter without coupling persistence to parser constants" do
    custom_adapter = Class.new(HistoricalPayrollImports::QuickbooksOnlineAdapter) do
      def label = "Reviewed QuickBooks test adapter"
      def importer_version = "reviewed-quickbooks-test-v1"
      def supported_verification_versions = [ importer_version ]
    end.new
    custom_registry = described_class.new(adapters: [ custom_adapter ])
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")

    result = HistoricalPayrollImports::ImportService.new(
      company: company,
      files: quickbooks_history_uploads,
      actor: actor,
      source_system: custom_adapter.key,
      registry: custom_registry
    ).call

    expect(result).to be_success
    expect(result.batch).to have_attributes(
      source_system: custom_adapter.key,
      importer_version: custom_adapter.importer_version
    )
  ensure
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end
end
