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

    # CPR-71: correction traits
    trait :voided do
      status { "committed" }
      committed_at { 1.day.ago }
      correction_status { "voided" }
      voided_at { Time.current }
      void_reason { "Test void reason" }
    end

    trait :correction_run do
      status { "draft" }
      correction_status { "correction" }
    end
  end
end
