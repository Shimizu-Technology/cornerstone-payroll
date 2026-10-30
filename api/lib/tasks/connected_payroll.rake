# frozen_string_literal: true

namespace :connected_payroll do
  desc "Read the effective connected payroll mode without contacting the other app"
  task status: :environment do
    puts JSON.generate(ConnectedPayrollMode.capability)
  end
end
