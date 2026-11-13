# frozen_string_literal: true

module TestWorkspace
  # Copies calculation openings, not the source archive. A separate immutable
  # bridge snapshot retains the exact source revision in the workspace manifest.
  class OpeningYtdCloner
    def initialize(source_company:, company:, actor:, employees:, cutoff:, before_cutoff: false)
      @source_company, @company, @actor, @employees, @cutoff, @before_cutoff =
        source_company, company, actor, employees, cutoff, before_cutoff
    end

    def call
      errors = self.class.validation_errors(source_company: source_company, cutoff: cutoff, before_cutoff: before_cutoff)
      raise ArgumentError, errors.join("; ") if errors.any?

      lineage = []
      source_company.historical_import_batches.where(status: "locked").order(:id).each do |batch|
        bridge = batch.latest_applied_historical_ytd_bridge
        if !bridge && batch.importer_version.in?(HistoricalImportBatch::YTD_BRIDGE_IMPORTER_VERSIONS)
          raise ArgumentError, "Apply the source client’s opening YTD before copying this workspace"
        end
        next unless bridge

        target_batch = copy!(batch, company: company, created_by: actor, applied_by: actor, locked_by: actor,
          source_file_manifest: [])
        bootstrap = batch.historical_client_bootstrap && copy!(batch.historical_client_bootstrap,
          company: company, historical_import_batch: target_batch, created_by: actor, applied_by: actor)
        onboarding = batch.prior_provider_history_onboarding && copy!(batch.prior_provider_history_onboarding,
          company: company, historical_import_batch: target_batch, created_by: actor, activated_by: actor, reversed_by: nil)
        target_bridge = copy!(bridge, company: company, historical_import_batch: target_batch,
          historical_client_bootstrap: bootstrap, prior_provider_history_onboarding: onboarding,
          created_by: actor, applied_by: actor, revision: 1, supersedes_historical_ytd_bridge: nil)
        bridge.historical_employee_ytd_balances.order(:id).each do |balance|
          copy!(balance, company: company, historical_ytd_bridge: target_bridge, employee: employees.fetch(balance.employee_id))
        end
        verify!(bridge, target_bridge)
        lineage << { source_batch_id: batch.id, source_bridge_id: bridge.id, source_revision: bridge.revision,
          copied_batch_id: target_batch.id, copied_bridge_id: target_bridge.id, balance_count: target_bridge.historical_employee_ytd_balances.count }
      end
      company.update!(test_workspace_manifest: company.test_workspace_manifest.merge("opening_ytd" => lineage))
    end

    def self.validation_errors(source_company:, cutoff:, before_cutoff: false)
      source_company.historical_import_batches.where(status: "locked").filter_map do |batch|
        bridge = batch.latest_applied_historical_ytd_bridge
        if !bridge && batch.importer_version.in?(HistoricalImportBatch::YTD_BRIDGE_IMPORTER_VERSIONS)
          next "Apply the source client’s opening YTD before copying this workspace"
        end
        next unless bridge && cutoff

        summary = bridge.preview_summary
        end_date = Date.iso8601(summary.fetch("through_period_end"))
        pay_date = Date.iso8601(summary.fetch("through_pay_date"))
        valid = before_cutoff ? end_date < cutoff.start_date && pay_date < cutoff.pay_date : end_date <= cutoff.end_date && pay_date <= cutoff.pay_date
        "Choose a payroll cutoff after the imported opening YTD boundary" unless valid
      end.uniq
    end

    private

    attr_reader :source_company, :company, :actor, :employees, :cutoff, :before_cutoff

    def verify!(source, target)
      fields = HistoricalEmployeeYtdBalance.column_names - %w[id created_at updated_at company_id historical_ytd_bridge_id employee_id]
      expected = source.historical_employee_ytd_balances.order(:employee_id, :tax_year).map do |balance|
        [ employees.fetch(balance.employee_id).id, balance.tax_year, balance.attributes.slice(*fields) ]
      end.sort_by { |row| row.first(2) }
      actual = target.historical_employee_ytd_balances.order(:employee_id, :tax_year).map do |balance|
        [ balance.employee_id, balance.tax_year, balance.attributes.slice(*fields) ]
      end
      raise "Opening YTD copy verification failed" unless expected == actual
    end

    def copy!(source, **overrides)
      source.class.create!(source.attributes.except("id", "created_at", "updated_at").merge(overrides.stringify_keys))
    end
  end
end
