# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnnualTaxConfig, type: :model do
  describe "validations" do
    subject { build(:annual_tax_config) }

    it { is_expected.to be_valid }

    it "requires tax_year" do
      subject.tax_year = nil
      expect(subject).not_to be_valid
    end

    it "requires unique tax_year" do
      create(:annual_tax_config, tax_year: 2200)
      subject.tax_year = 2200
      expect(subject).not_to be_valid
    end

    it "requires ss_wage_base > 0" do
      subject.ss_wage_base = 0
      expect(subject).not_to be_valid
    end

    it "requires ss_rate between 0 and 1" do
      subject.ss_rate = 1.5
      expect(subject).not_to be_valid
    end
  end

  describe "associations" do
    it "has many filing_status_configs" do
      config = create(:annual_tax_config)
      fsc = create(:filing_status_config, annual_tax_config: config)
      expect(config.filing_status_configs).to include(fsc)
    end

    it "destroys associated filing_status_configs" do
      config = create(:annual_tax_config)
      create(:filing_status_config, annual_tax_config: config)
      expect { config.destroy }.to change(FilingStatusConfig, :count).by(-1)
    end
  end

  describe ".create_from_previous" do
    let!(:source) do
      config = create(:annual_tax_config, tax_year: 2300, ss_wage_base: 168_600)
      fsc = create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 14_600)
      create(:tax_bracket, filing_status_config: fsc, bracket_order: 1, min_income: 0, max_income: 11_600, rate: 0.10)
      create(:tax_bracket, filing_status_config: fsc, bracket_order: 2, min_income: 11_600, max_income: nil, rate: 0.12)
      config
    end

    it "creates a new config from previous year" do
      new_config = described_class.create_from_previous(2301, source_year: 2300)

      expect(new_config.tax_year).to eq(2301)
      expect(new_config.ss_wage_base).to eq(168_600)
      expect(new_config.is_active).to be false
    end

    it "copies filing status configs" do
      new_config = described_class.create_from_previous(2301, source_year: 2300)

      expect(new_config.filing_status_configs.count).to eq(1)
      expect(new_config.config_for("single").standard_deduction).to eq(14_600)
    end

    it "copies tax brackets" do
      new_config = described_class.create_from_previous(2301, source_year: 2300)
      fsc = new_config.config_for("single")

      expect(fsc.tax_brackets.count).to eq(2)
      expect(fsc.tax_brackets.first.rate).to eq(0.10)
    end
  end

  describe "#activate!" do
    it "activates the config and deactivates others" do
      old_active = create(:annual_tax_config, tax_year: 2401, is_active: true)
      new_config = create(:annual_tax_config, tax_year: 2402, is_active: false)

      new_config.activate!

      expect(new_config.reload.is_active).to be true
      expect(old_active.reload.is_active).to be false
    end
  end

  describe "#config_for" do
    it "returns the filing status config for the given status" do
      config = create(:annual_tax_config)
      fsc = create(:filing_status_config, annual_tax_config: config, filing_status: "married")

      expect(config.config_for("married")).to eq(fsc)
    end
  end
end
