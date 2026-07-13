# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxTable, type: :model do
  describe "#find_bracket" do
    it "treats a persisted nil maximum as an open-ended top bracket" do
      table = create(:tax_table)

      expect(table.reload.brackets.last[:max_income]).to be_nil
      expect(table.find_bracket(210_000)).to include(rate: 0.37, threshold: 23_998)
    end
  end
end
