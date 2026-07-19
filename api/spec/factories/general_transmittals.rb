# frozen_string_literal: true

FactoryBot.define do
  factory :general_transmittal do
    company
    title { "Quarterly Payment Packet" }
    transmittal_date { Date.new(2026, 5, 2) }
    preparer_name { "Cornerstone Tax Services" }
    recipient_name { "Client file" }
    notes { [ "Prepared for client delivery" ] }
    status { "draft" }

    trait :with_item do
      after(:build) do |transmittal|
        transmittal.items << build(:general_transmittal_item, general_transmittal: transmittal)
      end
    end
  end

  factory :general_transmittal_item do
    general_transmittal
    item_type { "manual" }
    title { "Quarterly return check" }
    payable_to { "Guam DRT" }
    check_number { "5001" }
    amount { 250.00 }
    details { [ "Q2 2026 return payment" ] }
    position { 0 }
  end

  factory :general_transmittal_artifact do
    general_transmittal
    company { general_transmittal.company }
    association :created_by, factory: :user
    sequence(:version_number)
    sequence(:storage_key) { |n| "general-transmittals/test/#{n}.pdf" }
    sequence(:filename) { |n| "transmittal_v#{n}.pdf" }
    content_type { "application/pdf" }
    byte_size { 1_024 }
    sha256 { "a" * 64 }
    template_version { GeneralTransmittalPdfGenerator::TEMPLATE_VERSION }
    snapshot { {} }
  end
end
