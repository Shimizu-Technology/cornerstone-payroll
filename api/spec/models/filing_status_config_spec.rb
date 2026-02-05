# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingStatusConfig, type: :model do
  describe "validations" do
    subject { build(:filing_status_config) }

    it { is_expected.to be_valid }

    it "requires valid filing_status" do
      subject.filing_status = "invalid"
      expect(subject).not_to be_valid
    end

    it "requires unique filing_status per annual_tax_config" do
      config = create(:annual_tax_config)
      create(:filing_status_config, annual_tax_config: config, filing_status: "single")
      subject.annual_tax_config = config
      subject.filing_status = "single"
      expect(subject).not_to be_valid
    end

    it "requires standard_deduction >= 0" do
      subject.standard_deduction = -100
      expect(subject).not_to be_valid
    end
  end

  describe "associations" do
    it "belongs to annual_tax_config" do
      fsc = create(:filing_status_config)
      expect(fsc.annual_tax_config).to be_present
    end

    it "has many tax_brackets" do
      fsc = create(:filing_status_config)
      bracket = create(:tax_bracket, filing_status_config: fsc)
      expect(fsc.tax_brackets).to include(bracket)
    end
  end

  describe "#standard_deduction_per_period" do
    it "calculates biweekly standard deduction" do
      fsc = build(:filing_status_config, standard_deduction: 14_600)
      expect(fsc.standard_deduction_per_period(26)).to eq(561.54)
    end
  end

  describe "#brackets_array" do
    it "returns brackets as array of hashes" do
      fsc = create(:filing_status_config)
      create(:tax_bracket, filing_status_config: fsc, min_income: 0, max_income: 11_600, rate: 0.10)

      brackets = fsc.brackets_array
      expect(brackets.first[:min_income]).to eq(0)
      expect(brackets.first[:rate]).to eq(0.10)
    end
  end
end
