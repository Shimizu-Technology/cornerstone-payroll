# frozen_string_literal: true

require "rails_helper"

RSpec.describe MfaPolicy do
  describe ".required_for?" do
    it "requires MFA for every role, employees included, only when enabled" do
      enabled = { "REQUIRE_MFA" => "on" }
      expect(User.roles.keys).to match_array(%w[super_admin admin org_admin manager accountant client employee portal_employee])
      User.roles.each_key do |role|
        user = User.new(role: role)
        expect(described_class.required_for?(user: user, env: enabled)).to be(true), role
        expect(described_class.required_for?(user: user, env: {})).to be(false), role
        expect(described_class.required_for?(user: user, env: { "REQUIRE_MFA" => "false" })).to be(false), role
      end
    end

    it "never requires MFA for a missing user" do
      expect(described_class.required_for?(user: nil, env: { "REQUIRE_MFA" => "true" })).to be(false)
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
    it "requires boolean enrollment even when Clerk has set a second-factor age" do
      expect(described_class.verified_second_factor?("fva" => [ 1, 0 ])).to be(false)
      [ nil, false, "true", 1 ].each do |enrollment|
        expect(described_class.verified_second_factor?("fva" => [ 1, 0 ], "two_factor_enabled" => enrollment)).to be(false)
      end
      expect(described_class.verified_second_factor?("fva" => [ 1, 0 ], "two_factor_enabled" => true)).to be(true)
    end

    it "allows the first factor's unverified sentinel and requires both ages to be valid integers" do
      expect(described_class.verified_second_factor?("two_factor_enabled" => true, "fva" => [ -1, 0 ])).to be(true)
      [ [ -2, 0 ], [ "5", 0 ], [ nil, 0 ], [ 0.5, 0 ], [ 5, -1 ], [ 5, nil ] ].each do |ages|
        expect(described_class.verified_second_factor?("two_factor_enabled" => true, "fva" => ages)).to be(false)
      end
    end

    it "returns false for non-Hash payloads" do
      [ nil, [], "token", 1 ].each do |payload|
        expect(described_class.verified_second_factor?(payload)).to be(false)
      end
    end
  end

  describe ".recently_verified_second_factor?" do
    it "uses an inclusive ten-minute cutoff by default and accepts an explicit window" do
      expect(described_class.recently_verified_second_factor?({ "two_factor_enabled" => true, "fva" => [ 5, 0 ] })).to be(true)
      expect(described_class.recently_verified_second_factor?({ "two_factor_enabled" => true, "fva" => [ 5, 10 ] })).to be(true)
      expect(described_class.recently_verified_second_factor?({ "two_factor_enabled" => true, "fva" => [ 5, 15 ] })).to be(false)
      expect(described_class.recently_verified_second_factor?({ "two_factor_enabled" => true, "fva" => [ 5, 15 ] }, max_age_minutes: 15)).to be(true)
    end

    it "requires a nonnegative integer window" do
      payload = { "two_factor_enabled" => true, "fva" => [ 5, 0 ] }
      expect(described_class.recently_verified_second_factor?(payload, max_age_minutes: 0)).to be(true)
      [ nil, -1, "10", 0.5, Float::INFINITY, Float::NAN ].each do |window|
        expect(described_class.recently_verified_second_factor?(payload, max_age_minutes: window)).to be(false)
      end
    end

    it "rejects missing, unverified and malformed claims" do
      [ {}, { "two_factor_enabled" => true, "fva" => [ 5, -1 ] }, { "two_factor_enabled" => true, "fva" => [ 5, nil ] }, { "two_factor_enabled" => true, "fva" => [ 5, "0" ] } ].each do |payload|
        expect(described_class.recently_verified_second_factor?(payload)).to be(false)
      end
    end
  end

  describe ".recently_verified_first_factor?" do
    it "requires a fresh first factor regardless of the second factor age" do
      [ [ 3, -1 ], [ 10, -1 ], [ 3, 25 ] ].each do |ages|
        expect(described_class.recently_verified_first_factor?({ "fva" => ages })).to be(true)
      end
      [ nil, [ 25, -1 ], [ -1, 0 ], [ "3", -1 ], [ 3 ], [ 3, nil ] ].each do |ages|
        expect(described_class.recently_verified_first_factor?({ "fva" => ages })).to be(false)
      end
      expect(described_class.recently_verified_first_factor?(nil)).to be(false)
      expect(described_class.recently_verified_first_factor?({ "fva" => [ 3, -1 ] }, max_age_minutes: -1)).to be(false)
    end
  end

  describe ".step_up_level" do
    it "asks for a second factor with MFA on and a first factor while it's off" do
      expect(described_class.step_up_level(env: { "REQUIRE_MFA" => "true" })).to eq("second_factor")
      expect(described_class.step_up_level(env: { "REQUIRE_MFA" => "false" })).to eq("first_factor")
      expect(described_class.step_up_level(env: {})).to eq("first_factor")
    end
  end

  describe ".recently_step_up_verified?" do
    let(:on) { { "REQUIRE_MFA" => "true" } }
    let(:off) { {} }

    it "accepts a fresh first factor while MFA is off, with or without enrollment" do
      expect(described_class.recently_step_up_verified?({ "fva" => [ 2, -1 ] }, env: off)).to be(true)
      expect(described_class.recently_step_up_verified?({ "fva" => [ 10, -1 ], "two_factor_enabled" => false }, env: off)).to be(true)
      expect(described_class.recently_step_up_verified?({ "fva" => [ 11, -1 ] }, env: off)).to be(false)
      # A fresh second factor alone isn't the first-factor reverification Clerk prompts for.
      expect(described_class.recently_step_up_verified?({ "fva" => [ 30, 0 ], "two_factor_enabled" => true }, env: off)).to be(false)
      expect(described_class.recently_step_up_verified?(nil, env: off)).to be(false)
    end

    it "requires an enrolled, fresh second factor when MFA is on" do
      expect(described_class.recently_step_up_verified?({ "fva" => [ 30, 4 ], "two_factor_enabled" => true }, env: on)).to be(true)
      expect(described_class.recently_step_up_verified?({ "fva" => [ 0, -1 ], "two_factor_enabled" => false }, env: on)).to be(false)
      expect(described_class.recently_step_up_verified?({ "fva" => [ 0, 0 ] }, env: on)).to be(false)
      expect(described_class.recently_step_up_verified?({ "fva" => [ 0, 11 ], "two_factor_enabled" => true }, env: on)).to be(false)
    end
  end
end
