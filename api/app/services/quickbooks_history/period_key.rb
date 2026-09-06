# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  module PeriodKey
    module_function

    def call(row)
      Digest::SHA256.hexdigest(
        [ row.fetch(:period_start), row.fetch(:period_end), row.fetch(:pay_date), row.fetch(:period_type) ].join("|")
      )
    end
  end
end
