# frozen_string_literal: true

FactoryBot.define do
  factory :historical_client_bootstrap do
    company
    historical_import_batch { association(:historical_import_batch, company: company) }
    sequence(:plan_digest) { |number| Digest::SHA256.hexdigest("historical-client-bootstrap-#{number}") }
    status { "previewed" }
  end
end
