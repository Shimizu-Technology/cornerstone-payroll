# frozen_string_literal: true

module HistoricalPayrollImports
  class ImportService
    def initialize(company:, files:, actor: nil, source_system: nil, registry: Registry.default)
      @company = company
      @files = files
      @actor = actor
      @adapter = registry.fetch!(source_system)
    end

    def call
      QuickbooksHistory::ImportService.new(
        company: company,
        files: files,
        actor: actor,
        adapter: adapter
      ).call
    end

    private

    attr_reader :company, :files, :actor, :adapter
  end
end
