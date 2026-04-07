# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollReminderConfig, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "is valid with defaults" do
      config = described_class.new(company: company)
      expect(config).to be_valid
    end

    it "validates days_before_due is positive" do
      config = described_class.new(company: company, days_before_due: 0)
      expect(config).not_to be_valid
      expect(config.errors[:days_before_due]).to be_present
    end

    it "validates days_before_due is not more than 14" do
      config = described_class.new(company: company, days_before_due: 15)
      expect(config).not_to be_valid
    end

    it "requires recipients when enabled" do
      config = described_class.new(company: company, enabled: true, recipients: [])
      expect(config).not_to be_valid
      expect(config.errors[:recipients]).to be_present
    end

    it "validates email format in recipients" do
      config = described_class.new(company: company, recipients: ["not-an-email"])
      expect(config).not_to be_valid
      expect(config.errors[:recipients].first).to include("invalid email")
    end

    it "accepts valid recipients" do
      config = described_class.new(company: company, enabled: true, recipients: ["test@example.com"])
      expect(config).to be_valid
    end

    it "enforces one config per company" do
      create(:payroll_reminder_config, company: company)
      dup = described_class.new(company: company)
      expect { dup.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
