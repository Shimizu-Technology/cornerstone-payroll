# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollWageRateInput do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:original) { create(:pay_period, company: company) }
  let(:source_item) { create(:payroll_item, company: company, employee: employee, pay_period: original, wage_rate_hours: saved) }
  let(:period) { create(:pay_period, :correction_run, company: company, source_pay_period: original) }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period, timekeeping_source: "correction_reference") }
  let(:saved) { [ { "label" => "Legacy", "rate" => 25, "regular_hours" => 4, "is_primary" => true, "active" => false } ] }
  let(:submitted) { { "label" => "Legacy", "rate" => 25, "regular_hours" => 3, "is_primary" => false, "active" => true } }

  before { source_item }

  def normalize(entry = submitted)
    described_class.normalize(payroll_item: item, entries: [ entry ]).sole
  end

  it "rejects an invented legacy bucket in a correction" do
    expect { normalize(submitted.merge("label" => "Invented", "rate" => 999)) }.to raise_error(ArgumentError, /original/)
  end

  it "rejects changing the captured rate of a matching legacy bucket" do
    expect { normalize(submitted.merge("rate" => 99)) }.to raise_error(ArgumentError, /reviewed wage-rate correction/)
  end

  it "retains original legacy metadata while accepting edited hours" do
    expect(normalize).to include("employee_wage_rate_id" => nil, "label" => "Legacy", "rate" => 25.0,
      "regular_hours" => 3, "is_primary" => true, "active" => source_item.wage_rate_hours.sole["active"])
  end

  it "rejects missing and ambiguous original legacy proof" do
    source_item.update!(wage_rate_hours: [])
    expect { normalize }.to raise_error(ArgumentError, /original/)
    source_item.update!(wage_rate_hours: saved + saved)
    expect { normalize }.to raise_error(ArgumentError, /original/)
  end

  it "rejects a blank original label" do
    expect { normalize(submitted.merge("label" => "")) }.to raise_error(ArgumentError, /original/)
  end

  it "rejects removed modern identities even at the original label and rate" do
    rate = employee.employee_wage_rates.create!(label: "Legacy", rate: 25)
    source_item.update!(wage_rate_hours: [ submitted.merge("employee_wage_rate_id" => rate.id) ])
    [ nil, "" ].each do |id|
      expect { normalize(submitted.merge("employee_wage_rate_id" => id)) }.to raise_error(ArgumentError, /original/)
    end
  end

  it "rejects a legacy label also used by a modern bucket" do
    rate = employee.employee_wage_rates.create!(label: "Legacy", rate: 25)
    source_item.update!(wage_rate_hours: saved + [ submitted.merge("employee_wage_rate_id" => rate.id) ])
    expect { normalize }.to raise_error(ArgumentError, /original/)
  end

  it "fails closed when the declared correction source has no employee item" do
    source_item.destroy!
    expect { normalize }.to raise_error(ArgumentError, /original/)
  end

  it "fails closed for a foreign correction source" do
    allow(period).to receive(:source_pay_period).and_return(create(:pay_period))
    allow(item).to receive(:pay_period).and_return(period)
    expect { normalize }.to raise_error(ArgumentError, /original/)
  end

  it "retains deleted modern profile rates from the original snapshot" do
    rate = employee.employee_wage_rates.create!(label: "Captured", rate: 25)
    entry = submitted.merge("employee_wage_rate_id" => rate.id, "label" => "Captured")
    source_item.update!(wage_rate_hours: [ entry.merge("active" => false) ])
    rate.destroy_with_employee_lock!
    expect(normalize(entry.merge("regular_hours" => 2, "active" => true))).to include("rate" => 25.0, "active" => source_item.reload.wage_rate_hours.sole["active"], "regular_hours" => 2)
  end

  it "preserves ordinary legacy input" do
    item.update!(timekeeping_source: "manual")
    expect(normalize(submitted.merge("label" => "New", "rate" => 99))).to eq(submitted.merge("label" => "New", "rate" => 99))
  end

  it "preserves supplemental correction references without a full correction-run source" do
    supplemental = create(:pay_period, company: company, cycle: "supplemental", corrects_pay_period: original)
    item.update!(pay_period: supplemental, correction_for_payroll_item: source_item)
    expect(normalize).to eq(submitted)
  end

  it "preserves historical simulation references without a declared correction source" do
    item.update!(pay_period: create(:pay_period, company: company))
    expect(normalize).to eq(submitted)
  end
end
