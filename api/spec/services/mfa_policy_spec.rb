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

  # Every step-up check dates the factor at request time: fva (whole minutes
  # when Clerk issued the token) plus the time since iat, rounded up.
  let(:now) { Time.zone.parse("2030-01-15 12:00:00") }

  def claims(fva, iat: now.to_i, **extra)
    { "fva" => fva, "iat" => iat }.merge(extra.transform_keys(&:to_s))
  end

  describe ".factor_age_minutes" do
    it "adds the time since the token was issued, rounded up to a whole minute" do
      expect(described_class.factor_age_minutes(claims([ 4, -1 ]), 0, now: now)).to eq(4)
      expect(described_class.factor_age_minutes(claims([ 4, -1 ], iat: now.to_i - 1), 0, now: now)).to eq(5)
      expect(described_class.factor_age_minutes(claims([ 4, -1 ], iat: now.to_i - 60), 0, now: now)).to eq(5)
      expect(described_class.factor_age_minutes(claims([ 4, -1 ], iat: now.to_i - 61), 0, now: now)).to eq(6)
      expect(described_class.factor_age_minutes(claims([ 30, 2 ], iat: now.to_i - 150), 1, now: now)).to eq(5)
    end

    it "can't date a factor from a missing, malformed or future iat, or an unverified factor" do
      [ nil, "#{now.to_i}", now.to_f - 1, now.to_i + 1 ].each do |iat|
        expect(described_class.factor_age_minutes(claims([ 0, 0 ], iat: iat), 0, now: now)).to be_nil, iat.inspect
      end
      expect(described_class.factor_age_minutes({ "fva" => [ 0, 0 ] }, 0, now: now)).to be_nil
      expect(described_class.factor_age_minutes(claims([ 0, -1 ]), 1, now: now)).to be_nil
      expect(described_class.factor_age_minutes(claims([ 0, "1" ]), 0, now: now)).to be_nil
    end
  end

  describe ".recently_verified_second_factor?" do
    let(:enrolled) { { two_factor_enabled: true } }

    it "accepts only an age strictly under the ten-minute window, counting time since iat" do
      expect(described_class.recently_verified_second_factor?(claims([ 5, 0 ], **enrolled), now: now)).to be(true)
      expect(described_class.recently_verified_second_factor?(claims([ 5, 9 ], **enrolled), now: now)).to be(true)
      expect(described_class.recently_verified_second_factor?(claims([ 5, 10 ], **enrolled), now: now)).to be(false)
      # fva says 9 minutes, but the token was issued a second ago: the factor may be 10 minutes old now.
      expect(described_class.recently_verified_second_factor?(claims([ 5, 9 ], iat: now.to_i - 1, **enrolled), now: now)).to be(false)
      # A token Clerk issued right after a verification goes stale once it's old enough itself.
      expect(described_class.recently_verified_second_factor?(claims([ 5, 0 ], iat: now.to_i - 9.minutes.to_i, **enrolled), now: now)).to be(true)
      expect(described_class.recently_verified_second_factor?(claims([ 5, 0 ], iat: now.to_i - 9.minutes.to_i - 1, **enrolled), now: now)).to be(false)
    end

    it "accepts an explicit window" do
      payload = claims([ 5, 14 ], **enrolled)
      expect(described_class.recently_verified_second_factor?(payload, now: now)).to be(false)
      expect(described_class.recently_verified_second_factor?(payload, max_age_minutes: 15, now: now)).to be(true)
    end

    it "requires a positive integer window" do
      payload = claims([ 5, 0 ], **enrolled)
      [ nil, 0, -1, "10", 0.5, Float::INFINITY, Float::NAN ].each do |window|
        expect(described_class.recently_verified_second_factor?(payload, max_age_minutes: window, now: now)).to be(false)
      end
    end

    it "rejects missing, unverified and malformed claims" do
      [ {}, claims([ 5, -1 ], **enrolled), claims([ 5, nil ], **enrolled), claims([ 5, "0" ], **enrolled), claims([ 5, 0 ]),
        claims([ 5, 0 ], iat: nil, **enrolled), claims([ 5, 0 ], iat: now.to_i + 30, **enrolled) ].each do |payload|
        expect(described_class.recently_verified_second_factor?(payload, now: now)).to be(false), payload.inspect
      end
    end
  end

  describe ".recently_verified_first_factor?" do
    it "requires a fresh first factor regardless of the second factor age" do
      [ [ 3, -1 ], [ 9, -1 ], [ 3, 25 ] ].each do |ages|
        expect(described_class.recently_verified_first_factor?(claims(ages), now: now)).to be(true)
      end
      [ nil, [ 10, -1 ], [ 25, -1 ], [ -1, 0 ], [ "3", -1 ], [ 3 ], [ 3, nil ] ].each do |ages|
        expect(described_class.recently_verified_first_factor?(claims(ages), now: now)).to be(false)
      end
      expect(described_class.recently_verified_first_factor?(claims([ 9, -1 ], iat: now.to_i - 30), now: now)).to be(false)
      expect(described_class.recently_verified_first_factor?(nil, now: now)).to be(false)
      expect(described_class.recently_verified_first_factor?(claims([ 3, -1 ]), max_age_minutes: -1, now: now)).to be(false)
    end

    it "treats a token without a usable iat as not verified" do
      [ nil, "now", now.to_i + 1 ].each do |iat|
        expect(described_class.recently_verified_first_factor?(claims([ 0, -1 ], iat: iat), now: now)).to be(false), iat.inspect
      end
    end

    it "uses the current time by default" do
      expect(described_class.recently_verified_first_factor?(claims([ 0, -1 ], iat: Time.current.to_i - 5))).to be(true)
      expect(described_class.recently_verified_first_factor?(claims([ 0, -1 ], iat: Time.current.to_i - 11.minutes.to_i))).to be(false)
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
      expect(described_class.recently_step_up_verified?(claims([ 2, -1 ]), env: off, now: now)).to be(true)
      expect(described_class.recently_step_up_verified?(claims([ 9, -1 ], two_factor_enabled: false), env: off, now: now)).to be(true)
      expect(described_class.recently_step_up_verified?(claims([ 10, -1 ]), env: off, now: now)).to be(false)
      # A fresh second factor alone isn't the first-factor reverification Clerk prompts for.
      expect(described_class.recently_step_up_verified?(claims([ 30, 0 ], two_factor_enabled: true), env: off, now: now)).to be(false)
      expect(described_class.recently_step_up_verified?(nil, env: off, now: now)).to be(false)
    end

    it "requires an enrolled, fresh second factor when MFA is on" do
      expect(described_class.recently_step_up_verified?(claims([ 30, 4 ], two_factor_enabled: true), env: on, now: now)).to be(true)
      expect(described_class.recently_step_up_verified?(claims([ 0, -1 ], two_factor_enabled: false), env: on, now: now)).to be(false)
      expect(described_class.recently_step_up_verified?(claims([ 0, 0 ]), env: on, now: now)).to be(false)
      expect(described_class.recently_step_up_verified?(claims([ 0, 10 ], two_factor_enabled: true), env: on, now: now)).to be(false)
      expect(described_class.recently_step_up_verified?(claims([ 0, 4 ], iat: nil, two_factor_enabled: true), env: on, now: now)).to be(false)
    end
  end
end
