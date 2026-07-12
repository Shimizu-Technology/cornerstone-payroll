# frozen_string_literal: true

FactoryBot.define do
  factory :information_return_threshold do
    form_type { "1099_nec" }
    sequence(:tax_year) { |n| 2200 + n }
    threshold_amount { 600.00 }
    source_url { "https://www.irs.gov/instructions/i1099mec" }
    effective_on { Date.new(tax_year, 1, 1) }
  end
end
