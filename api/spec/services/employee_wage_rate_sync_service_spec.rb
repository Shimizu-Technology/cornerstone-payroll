# frozen_string_literal: true

require "rails_helper"

# M3-4: the sync service no longer saves on its own (its old #sync! overwrote
# rates in place and deleted omitted ones). It applies a wage-rate list only
# inside EmployeeCompensationChangeService, which dates and records the change.
RSpec.describe EmployeeWageRateSyncService do
  let!(:company) { create(:company) }
  let!(:employee) { create(:employee, company: company) }

  describe "#apply_under_compensation_context!" do
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

    def sync!(replace_missing: false)
      EmployeeCompensationChangeService.new(
        employee: employee, actor: nil, source: "staff", reason: "Spec sync",
        wage_rates: [ { id: regular_rate.id, label: "Regular", rate: 19.5, is_primary: true, active: true } ],
        replace_missing_wage_rates: replace_missing
      ).call!
    end

    it "preserves omitted wage rates by default" do
      sync!

      expect(employee.reload.employee_wage_rates.order(:label).pluck(:label, :rate).map { |label, rate| [ label, rate.to_f ] }).to eq([
        [ "Overtime", 27.0 ],
        [ "Regular", 19.5 ]
      ])
    end

    it "ends omitted wage rates during full replacement syncs instead of deleting them" do
      sync!(replace_missing: true)

      expect(employee.reload.active_wage_rates.map { |rate| [ rate.label, rate.rate.to_f ] }).to eq([ [ "Regular", 19.5 ] ])
      expect(overtime_rate.reload).to have_attributes(active: false, rate: 27.0)
      # Nothing is paid yet, so the default date is the start of the
      # employee's history and the removal replaces the setup version.
      expect(overtime_rate.employee_wage_rate_versions.sole).to have_attributes(active: false, effective_on: employee.hire_date)
    end

    it "refuses to change rates outside the compensation service" do
      expect do
        described_class.new(employee: employee, wage_rates: [ { id: regular_rate.id, label: "Regular", rate: 1 } ]).apply_under_compensation_context!
      end.to raise_error(EmployeeCompensationChangeService::CompensationMutationError)
      expect(regular_rate.reload.rate).to eq(18)
    end
  end
end
