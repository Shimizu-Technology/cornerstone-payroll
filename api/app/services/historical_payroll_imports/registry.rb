# frozen_string_literal: true

module HistoricalPayrollImports
  class Registry
    DEFAULT_SOURCE_SYSTEM = "quickbooks_online"

    def self.default
      @default ||= new(adapters: [ QuickbooksOnlineAdapter.new ])
    end

    def initialize(adapters:)
      @adapters = Array(adapters).to_h do |adapter|
        adapter.validate_contract!
        [ adapter.key, adapter ]
      end
      raise ArgumentError, "Historical import adapter keys must be unique" unless @adapters.size == Array(adapters).size
    end

    def fetch!(key)
      source_system = key.to_s.presence || DEFAULT_SOURCE_SYSTEM
      adapters.fetch(source_system) do
        raise ArgumentError, "Unsupported historical payroll source: #{source_system}"
      end
    end

    def find(key)
      adapters[key.to_s]
    end

    def keys
      adapters.keys.freeze
    end

    def contracts
      adapters.values.map(&:contract)
    end

    private

    attr_reader :adapters
  end
end
