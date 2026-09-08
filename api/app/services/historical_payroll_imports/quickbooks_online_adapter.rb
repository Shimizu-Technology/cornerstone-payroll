# frozen_string_literal: true

module HistoricalPayrollImports
  class QuickbooksOnlineAdapter < Adapter
    KEY = "quickbooks_online"
    LABEL = "QuickBooks Online Payroll"
    SUPPORTED_VERIFICATION_VERSIONS = %w[
      quickbooks-online-payroll-v2
      quickbooks-online-payroll-v3
      quickbooks-online-payroll-v4
      quickbooks-online-payroll-v5
    ].freeze
    TAX_WAGE_VERSIONS = %w[quickbooks-online-payroll-v5].freeze
    LEGACY_WORKER_SNAPSHOT_VERSIONS = %w[
      quickbooks-online-payroll-v2
      quickbooks-online-payroll-v3
    ].freeze

    def key = KEY
    def label = LABEL
    def description = "Import a complete retained QuickBooks payroll export bundle and reconcile it before use."
    def importer_version = parser_class::IMPORTER_VERSION
    def parser_class = QuickbooksHistory::BundleParser
    def accepted_extensions = parser_class::ALLOWED_EXTENSIONS
    def max_files = parser_class::MAX_FILE_COUNT
    def max_file_bytes = parser_class::MAX_FILE_BYTES
    def max_bundle_bytes = parser_class::MAX_BUNDLE_BYTES
    def supported_verification_versions = SUPPORTED_VERIFICATION_VERSIONS
    def tax_wage_versions = TAX_WAGE_VERSIONS
    def legacy_worker_snapshot_versions = LEGACY_WORKER_SNAPSHOT_VERSIONS

    def capabilities
      {
        source_file_retention: true,
        cutover_verification: true,
        client_bootstrap: true,
        ytd_bridge: true
      }
    end

    def limitations
      [
        "Requires the complete supported QuickBooks report set; arbitrary spreadsheets are not accepted.",
        "Opening summaries remain separate when paycheck-level source detail is unavailable.",
        "Imported source values are retained and never recalculated by Cornerstone."
      ]
    end
  end
end
