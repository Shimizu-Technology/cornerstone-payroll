require "rails_helper"

RSpec.describe W2GuAggregator do
  let(:company) { create(:company, name: "Guam Biz Inc", ein: "91-1234567") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, ssn_encrypted: "123-45-6789") }

  describe "#generate" do
    it "logs a warning when reported tips exceed gross pay" do
      pay_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))

      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        gross_pay: 50.0,
        reported_tips: 100.0,
        withholding_tax: 0.0,
        social_security_tax: 3.1,
        medicare_tax: 0.73)

      allow(Rails.logger).to receive(:warn)

      described_class.new(company, 2025).generate

      expect(Rails.logger).to have_received(:warn).with(include("reported_tips=100.0 exceed gross_pay=50.0"))
    end
  end
end
