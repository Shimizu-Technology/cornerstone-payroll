# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Legacy employer benefit statements" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:prior_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 3)) }
  let(:period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 17)) }
  let!(:prior) { create(:payroll_item, employee: employee, pay_period: prior_period, gross_pay: 1000, retirement_payment: 50) }
  let(:item) { create(:payroll_item, :with_check, employee: employee, pay_period: period) }

  before do
    definition = create(:payroll_field_definition, company: company, name: "Saved employer health",
      kind: "employer_contribution", tax_treatment: "employer_contribution", category: "benefit")
    prior.payroll_item_field_entries.create!(payroll_field_definition: definition, label: definition.name,
      kind: definition.kind, tax_treatment: definition.tax_treatment, category: definition.category,
      amount: 25, active: true, metadata: {})
    type = company.deduction_types.create!(name: definition.name, category: "employer_contribution", sub_category: "benefit")
    prior.payroll_item_deductions.create!(deduction_type: type, label: definition.name, category: "employer_contribution", amount: 25)
  end

  [ PayStubGenerator, CheckGenerator ].each do |generator_class|
    it "renders #{generator_class} with prior legacy benefits counted once and saved payroll unchanged" do
      saved = [ prior.reload.attributes, item.reload.attributes ]
      generator = generator_class.new(item)
      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")
      expect(text).to include("Saved employer health", "25.00", "2,200.00")
      expect(text.scan(PayrollReportComponentReview::MESSAGE).size).to eq(generator_class == CheckGenerator ? 2 : 1)
      rows = PayrollStatementYtdBreakdown.new(item).employer_contributions
      expect(rows.select { |row| row.label == "Saved employer health" }.sum(&:ytd)).to eq(25)
      expect([ prior.reload.attributes, item.reload.attributes ]).to eq(saved)
    end
  end

  it "keeps calculator YTD strict after rendering a lenient statement on the same employee instance" do
    expect(item.employee).to equal(employee)
    snapshot = employee.cached_ytd_snapshot
    PayStubGenerator.new(item).generate
    expect(employee.cached_ytd_snapshot).to eq(snapshot)
    employee.restore_cached_ytd_snapshot!(snapshot)
    expect { PayrollCalculator.new(employee, item).send(:update_ytd_on_item) }
      .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
  end

  it "bypasses restored calculation caches for reporting without changing their strict values" do
    employee.cache_ytd_values!(year: 2026, as_of_pay_date: period.pay_date,
      before_pay_period_id: period.id, totals: { gross_pay: 9999, retirement: 888 })
    snapshot = employee.cached_ytd_snapshot
    employee.restore_cached_ytd_snapshot!(snapshot)
    args = { year: 2026, pay_date: period.pay_date, pay_period_id: period.id }
    expect(employee.ytd_totals_before(**args, for_reporting: true)).to include(gross_pay: 1000, retirement: 50)
    PayStubGenerator.new(item).generate
    CheckGenerator.new(item).generate
    expect(employee.cached_ytd_snapshot).to eq(snapshot)
    expect(employee.ytd_totals_before(**args)).to include(gross_pay: 9999, retirement: 888)
  end

  it "does not relax structurally ambiguous prior history for either PDF" do
    type = company.deduction_types.create!(name: "Another employer health", category: "employer_contribution", sub_category: "benefit")
    prior.payroll_item_deductions.create!(deduction_type: type, label: "Saved employer health", category: "employer_contribution", amount: 25)
    [ PayStubGenerator, CheckGenerator ].each do |generator_class|
      expect { generator_class.new(item).generate }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
    end
  end

  it "omits the review note when prior history has no unclassified benefit" do
    prior.payroll_item_field_entries.destroy_all
    prior.payroll_item_deductions.destroy_all
    [ PayStubGenerator, CheckGenerator ].each do |generator_class|
      text = PDF::Reader.new(StringIO.new(generator_class.new(item).generate)).pages.map(&:text).join("\n")
      expect(text).not_to include(PayrollReportComponentReview::MESSAGE)
    end
  end
end
