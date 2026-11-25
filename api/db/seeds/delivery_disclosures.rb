# frozen_string_literal: true

puts "Seeding draft electronic-delivery disclosures..."
records = DeliveryDisclosures::DraftSeeds.seed!
puts "  Seeded #{records.size} delivery disclosure(s) (#{DeliveryDisclosures::DraftSeeds::DRAFT_VERSION})"
