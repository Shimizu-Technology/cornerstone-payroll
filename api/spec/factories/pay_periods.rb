# frozen_string_literal: true

FactoryBot.define do
  factory :pay_period do
    company
    start_date { Date.new(2024, 1, 1) }
    end_date { Date.new(2024, 1, 14) }
    pay_date { Date.new(2024, 1, 19) }
    status { "draft" }

    trait :calculated do
      status { "calculated" }
    end

    trait :approved do
      status { "approved" }
    end

    trait :committed do
      status { "committed" }
      committed_at { Time.current }
    end
  end
end
