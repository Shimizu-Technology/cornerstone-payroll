# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSourceCoverage do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }

  it "does not require acknowledgement for manual and salary-only clients without a scheduled source" do
    expect(described_class.acknowledgement_required?(period)).to be(false)
    source
    expect(described_class.acknowledgement_required?(period)).to be(false)
  end

  it "requires acknowledgement for a scheduled source until a finalized batch is applied" do
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period)
    expect(described_class.acknowledgement_required?(period)).to be(true)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source)
    expect(described_class.acknowledgement_required?(period)).to be(true)
    import.update!(status: "applied")
    expect(described_class.acknowledgement_required?(period)).to be(false)
  end

  it "does not treat an applied legacy nonfinalized import as coverage" do
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period)
    create(:time_tracking_import, pay_period: period, time_tracking_source: source, status: "applied")
    expect(described_class.acknowledgement_required?(period)).to be(true)
  end

  it "does not change special-run processing" do
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period)
    period.update!(run_purpose: "adjustment")
    expect(described_class.acknowledgement_required?(period)).to be(false)
  end
end
