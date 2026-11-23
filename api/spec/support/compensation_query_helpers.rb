# frozen_string_literal: true

module CompensationQueryHelpers
  def compensation_read_queries(*tables, &block)
    watched = %w[employee_compensation_changes employee_wage_rates employee_wage_rate_versions] + tables
    from = /FROM "(?:#{Regexp.union(watched)})"/i
    queries = []
    listener = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:sql].match?(from) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record", &block)
    queries
  end
end

RSpec.configure { |config| config.include CompensationQueryHelpers }
