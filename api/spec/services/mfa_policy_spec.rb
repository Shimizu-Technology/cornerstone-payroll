# frozen_string_literal: true

require "rails_helper"

RSpec.describe MfaPolicy do
  describe ".required_for?" do
    it "only requires MFA for staff or client roles with the switch enabled" do
      enabled = { "REQUIRE_MFA" => "on" }
      %i[super_admin admin org_admin manager accountant client].each do |role|
        expect(described_class.required_for?(user: User.new(role: role), env: enabled)).to be(true)
      end
      %i[employee portal_employee].each do |role|
        expect(described_class.required_for?(user: User.new(role: role), env: enabled)).to be(false)
      end
      expect(described_class.required_for?(user: User.new(role: :admin), env: {})).to be(false)
    end

    it "accepts explicit truthy values and leaves unset or unrecognized values off" do
      %w[1 true t yes y on TRUE].each do |value|
        expect(described_class.enabled?(env: { "REQUIRE_MFA" => value })).to be(true)
      end
      [ nil, "", "false", "0", "enabled" ].each do |value|
        expect(described_class.enabled?(env: { "REQUIRE_MFA" => value })).to be(false)
      end
    end
  end

  describe ".recently_verified?" do
    it "uses an inclusive ten-minute cutoff by default and accepts an explicit window" do
      expect(described_class.recently_verified?({ "fva" => [ 5, 0 ] })).to be(true)
      expect(described_class.recently_verified?({ "fva" => [ 5, 10 ] })).to be(true)
      expect(described_class.recently_verified?({ "fva" => [ 5, 15 ] })).to be(false)
      expect(described_class.recently_verified?({ "fva" => [ 5, 15 ] }, max_age_minutes: 15)).to be(true)
    end

    it "rejects missing, unverified and malformed claims" do
      [ {}, { "fva" => [ 5, -1 ] }, { "fva" => [ 5, nil ] }, { "fva" => [ 5, "0" ] } ].each do |payload|
        expect(described_class.recently_verified?(payload)).to be(false)
      end
    end
  end
end
