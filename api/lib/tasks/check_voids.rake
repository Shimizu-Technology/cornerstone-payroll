# frozen_string_literal: true

require "csv"

namespace :payroll do
  desc "Read-only accountant review of legacy instrument voids without payroll reversal (CSV)"
  task legacy_check_voids: :environment do
    ApplicationRecord.transaction(requires_new: true) do
      ApplicationRecord.connection.execute("SET TRANSACTION READ ONLY")
      puts CSV.generate_line(%w[company_id pay_period_id payroll_item_id employee_id check_number gross_pay net_pay voided_at reason])
      LegacyCheckVoidDetection.items.find_each do |item|
        puts CSV.generate_line([ item.company_id, item.pay_period_id, item.id, item.employee_id,
          item.check_number, item.gross_pay.to_s("F"), item.net_pay.to_s("F"), item.voided_at&.iso8601, item.void_reason ])
      end
    end
  end
end
