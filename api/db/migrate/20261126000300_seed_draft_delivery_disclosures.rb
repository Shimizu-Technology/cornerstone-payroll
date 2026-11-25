# frozen_string_literal: true

class SeedDraftDeliveryDisclosures < ActiveRecord::Migration[8.1]
  def up
    DeliveryDisclosures::DraftSeeds.seed!
  end

  def down
    # Leave seeded disclosures intact if any consent references them.
    DeliveryDisclosure.where(version: DeliveryDisclosures::DraftSeeds::DRAFT_VERSION, status: "draft")
      .where.missing(:delivery_consents)
      .delete_all
  end
end
