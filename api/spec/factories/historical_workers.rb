# frozen_string_literal: true

FactoryBot.define do
  factory :historical_worker do
    historical_import_batch
    company { historical_import_batch.company }
    sequence(:external_key) { |number| "historical-worker-#{number}" }
    sequence(:source_name) { |number| "Worker, Historical #{number}" }
    normalized_name { QuickbooksHistory::NameNormalizer.call(source_name) }
    source_status { "active" }
    mapping_status { "needs_review" }
    private_snapshot { JSON.generate({}) }
  end
end
