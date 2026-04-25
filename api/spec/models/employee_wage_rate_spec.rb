require "rails_helper"

RSpec.describe EmployeeWageRate, type: :model do
  describe "rate normalization" do
    it "rounds rate to cents before validation" do
      wage_rate = described_class.new(
        employee: create(:employee),
        label: "Base",
        rate: 9.974,
        is_primary: true,
        active: true
      )

      wage_rate.validate

      expect(wage_rate.rate.to_f).to eq(9.97)
    end
  end
end
