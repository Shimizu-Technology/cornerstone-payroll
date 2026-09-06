# frozen_string_literal: true

FactoryBot.define do
  factory :historical_import_batch do
    company
    source_system { "quickbooks_online" }
    sequence(:source_label) { |number| "QuickBooks history #{number}" }
    sequence(:bundle_digest) { |number| Digest::SHA256.hexdigest("historical-import-#{number}") }
    importer_version { QuickbooksHistory::BundleParser::IMPORTER_VERSION }
    status { "previewed" }
  end
end
