# frozen_string_literal: true

namespace :payroll do
  namespace :legacy_employer_benefits do
    desc "Read-only company/year inventory of unclassified legacy employer benefit candidates"
    task inventory: :environment do
      puts JSON.pretty_generate(PayrollLegacyEmployerBenefitInventory.call)
    end
  end
end
