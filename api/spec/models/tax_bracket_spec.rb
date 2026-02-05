# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxBracket, type: :model do
  describe "validations" do
    subject { build(:tax_bracket) }

    it { is_expected.to be_valid }

    it "requires bracket_order" do
      subject.bracket_order = nil
      expect(subject).not_to be_valid
    end

    it "requires unique bracket_order per filing_status_config" do
      fsc = create(:filing_status_config)
      create(:tax_bracket, filing_status_config: fsc, bracket_order: 1)
      subject.filing_status_config = fsc
      subject.bracket_order = 1
      expect(subject).not_to be_valid
    end

    it "requires min_income >= 0" do
      subject.min_income = -100
      expect(subject).not_to be_valid
    end

    it "allows nil max_income for top bracket" do
      subject.max_income = nil
      expect(subject).to be_valid
    end

    it "requires rate between 0 and 1" do
      subject.rate = 1.5
      expect(subject).not_to be_valid
    end
  end

  describe "#min_income_per_period" do
    it "calculates biweekly min income" do
      bracket = build(:tax_bracket, min_income: 11_600)
      expect(bracket.min_income_per_period(26)).to eq(446.15)
    end
  end

  describe "#max_income_per_period" do
    it "calculates biweekly max income" do
      bracket = build(:tax_bracket, max_income: 47_150)
      expect(bracket.max_income_per_period(26)).to eq(1813.46)
    end

    it "returns nil for top bracket" do
      bracket = build(:tax_bracket, max_income: nil)
      expect(bracket.max_income_per_period(26)).to be_nil
    end
  end
end
