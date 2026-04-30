# frozen_string_literal: true

FactoryBot.define do
  factory :cable_connection_ticket do
    user
    company { user.company }
    sequence(:token_digest) { |n| OpenSSL::Digest::SHA256.hexdigest("ticket-#{n}") }
    expires_at { 1.minute.from_now }
    used_at { nil }
  end
end
