# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeWageRateSyncService do
  let!(:company) { create(:company) }
  let!(:employee) { create(:employee, company: company) }

  describe "#sync!" do
    let!(:regular_rate) do
      employee.employee_wage_rates.create!(
        label: "Regular",
        rate: 18.0,
        is_primary: true,
        active: true
      )
    end

    let!(:overtime_rate) do
      employee.employee_wage_rates.create!(
        label: "Overtime",
        rate: 27.0,
        is_primary: false,
        active: true
      )
    end

    it "preserves omitted wage rates by default" do
      described_class.new(
        employee: employee,
        wage_rates: [
          {
            id: regular_rate.id,
            label: "Regular",
            rate: 19.5,
            is_primary: true,
            active: true
          }
        ]
      ).sync!

      expect(employee.reload.employee_wage_rates.order(:label).pluck(:label, :rate).map { |label, rate| [ label, rate.to_f ] }).to eq([
        [ "Overtime", 27.0 ],
        [ "Regular", 19.5 ]
      ])
    end

    it "removes omitted wage rates during full replacement syncs" do
      described_class.new(
        employee: employee,
        wage_rates: [
          {
            id: regular_rate.id,
            label: "Regular",
            rate: 19.5,
            is_primary: true,
            active: true
          }
        ],
        replace_missing: true
      ).sync!

      expect(employee.reload.employee_wage_rates.order(:label).pluck(:label, :rate).map { |label, rate| [ label, rate.to_f ] }).to eq([
        [ "Regular", 19.5 ]
      ])
    end
  end
end
