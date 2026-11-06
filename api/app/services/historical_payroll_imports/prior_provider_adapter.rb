# frozen_string_literal: true

module HistoricalPayrollImports
  class PriorProviderAdapter < QuickbooksOnlineAdapter
    def key = "prior_provider"
    def label = "Prior-provider paid history"
    def description = "Reconcile calculated runs or manual entries to retained paid registers and the existing employee roster."
    def importer_version = PriorProviderHistory::SourceAdapter::VERSION
    def supported_verification_versions = [ importer_version ]
    def tax_wage_versions = [ importer_version ]
    def legacy_worker_snapshot_versions = []
    def capabilities = super.merge(client_bootstrap: false)
    def limitations = [ "Use Client Management → Prior-provider history. One complete employer/year; no live payroll may be committed before activation." ]

    def parse(files:)
      raise ArgumentError, "Use Client Management → Prior-provider history to reconcile existing employees and paid registers"
    end
  end
end
