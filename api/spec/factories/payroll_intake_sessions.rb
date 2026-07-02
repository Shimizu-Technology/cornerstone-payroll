# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_intake_session do
    company
    pay_period { association(:pay_period, company: company) }
    source_type { "spike_email" }
    source_label { "Spike Coffee Roasters email" }
    status { "previewed" }
    sequence(:import_hash) { |n| Digest::SHA256.hexdigest("payroll-intake-#{n}") }
    parser_version { PayrollIntake::Adapters::SpikeEmail::PARSER_VERSION }
    warnings { [] }
    totals { {} }
  end
end
