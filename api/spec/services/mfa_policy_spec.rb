# frozen_string_literal: true

require "rails_helper"

RSpec.describe MfaPolicy do
  describe ".required_for?" do
    it "preserves the MFA requirement for all eight current roles" do
      enabled = { "REQUIRE_MFA" => "on" }
      requirements = {
        super_admin: true, admin: true, org_admin: true, manager: true, accountant: true, client: true,
        employee: false, portal_employee: false
      }
      expect(User.roles.keys).to match_array(requirements.keys.map(&:to_s))
      requirements.each do |role, required|
        user = User.new(role: role)
        expect(described_class.required_for?(user: user, env: enabled)).to eq(required), role.to_s
        expect(described_class.required_for?(user: user, env: {})).to be(false)
      end
    end

    it "requires MFA if the user's role is unrecognized" do
      user = User.new(role: nil)
      expect(described_class.required_for?(user: user, env: { "REQUIRE_MFA" => "true" })).to be(true)
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

  describe ".verified_second_factor?" do
    it "allows the first factor's unverified sentinel and requires both ages to be valid integers" do
      expect(described_class.verified_second_factor?("fva" => [ -1, 0 ])).to be(true)
      [ [ -2, 0 ], [ "5", 0 ], [ nil, 0 ], [ 0.5, 0 ], [ 5, -1 ], [ 5, nil ] ].each do |ages|
        expect(described_class.verified_second_factor?("fva" => ages)).to be(false)
      end
    end

    it "returns false for non-Hash payloads" do
      [ nil, [], "token", 1 ].each do |payload|
        expect(described_class.verified_second_factor?(payload)).to be(false)
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

    it "requires a nonnegative integer window" do
      payload = { "fva" => [ 5, 0 ] }
      expect(described_class.recently_verified?(payload, max_age_minutes: 0)).to be(true)
      [ nil, -1, "10", 0.5, Float::INFINITY, Float::NAN ].each do |window|
        expect(described_class.recently_verified?(payload, max_age_minutes: window)).to be(false)
      end
    end

    it "rejects missing, unverified and malformed claims" do
      [ {}, { "fva" => [ 5, -1 ] }, { "fva" => [ 5, nil ] }, { "fva" => [ 5, "0" ] } ].each do |payload|
        expect(described_class.recently_verified?(payload)).to be(false)
      end
    end
  end
end
