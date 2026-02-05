# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxConfigAuditLog, type: :model do
  describe "validations" do
    it "requires valid action" do
      log = build(:tax_config_audit_log, action: "invalid")
      expect(log).not_to be_valid
    end

    it "accepts valid actions" do
      %w[created updated activated deactivated].each do |action|
        log = build(:tax_config_audit_log, action: action)
        expect(log).to be_valid
      end
    end
  end

  describe "immutability" do
    it "is readonly after persisted" do
      log = create(:tax_config_audit_log)
      expect(log.readonly?).to be true
    end
  end

  describe ".log_created" do
    it "creates a creation log" do
      config = create(:annual_tax_config, tax_year: 4000)

      log = described_class.log_created(config, user_id: 123, ip_address: "127.0.0.1")

      expect(log.action).to eq("created")
      expect(log.new_value).to include("4000")
      expect(log.user_id).to eq(123)
      expect(log.ip_address).to eq("127.0.0.1")
    end
  end

  describe ".log_updated" do
    it "creates an update log" do
      config = create(:annual_tax_config)

      log = described_class.log_updated(
        config,
        field_name: "ss_wage_base",
        old_value: 160_200,
        new_value: 168_600
      )

      expect(log.action).to eq("updated")
      expect(log.field_name).to eq("ss_wage_base")
      expect(log.old_value).to eq("160200")
      expect(log.new_value).to eq("168600")
    end
  end

  describe ".log_activated" do
    it "creates an activation log" do
      config = create(:annual_tax_config, tax_year: 4001)

      log = described_class.log_activated(config)

      expect(log.action).to eq("activated")
      expect(log.new_value).to include("4001")
    end
  end

  describe ".log_deactivated" do
    it "creates a deactivation log" do
      config = create(:annual_tax_config, tax_year: 4002)

      log = described_class.log_deactivated(config)

      expect(log.action).to eq("deactivated")
      expect(log.new_value).to include("4002")
    end
  end
end
