# frozen_string_literal: true

require "rails_helper"

RSpec.describe Organization, type: :model do
  it "normalizes slugs from names" do
    organization = described_class.create!(name: "Acme Guam CPAs")

    expect(organization.slug).to eq("acme-guam-cpas")
  end
end
