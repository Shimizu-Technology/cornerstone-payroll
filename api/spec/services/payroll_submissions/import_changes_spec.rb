# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSubmissions::ImportChanges do
  let!(:company) { create(:company) }
  let!(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
  let!(:worker) { create(:employee, company: company, pay_rate: 35) }
  let!(:rate) { create(:employee_wage_rate, employee: worker, rate: 35, label: "Maintenance") }
  let!(:period) { create(:pay_period, company: company) }
  let!(:source_period) { PayrollSubmissionPeriod.create!(company: company, pay_period: period, source: "pay_period", start_date: period.start_date, end_date: period.end_date) }
  let!(:submission) do
    source_period.submissions.create!(company: company, revision: 1, submitted_at: Time.current,
      content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32), change_rows: changes)
  end
  let(:changes) do
    [ { kind: "owner_pay", employee_id: owner.id, amount: "8421.13" },
      { kind: "extra_hours", employee_id: worker.id, employee_wage_rate_id: rate.id, wage_rate: "35.0", hours: "68" } ]
  end
  let(:service) { described_class.new(submission: submission, pay_period: period) }
  let(:reviewed) { [ { change_index: 0, amount: "8421.13" }, { change_index: 1, hours: "68" } ] }
  let(:rows) { [ { employee_id: owner.id, workbook_only: true }, { employee_id: worker.id, workbook_only: true, loan_deduction: 219.70, total_tips: 3 } ] }

  it "does not write on preview and requires explicit complete confirmation" do
    expect { service.proposals }.not_to change(PayrollItem, :count)
    expect(service.proposals.first).to include(amount: "8421.13", employee_id: owner.id)
    expect { service.apply_to(rows, reviewed: reviewed, confirmed: false) }.to raise_error(ArgumentError, /Confirm/)
    expect { service.apply_to(rows, reviewed: reviewed.first(1), confirmed: true) }.to raise_error(ArgumentError, /every/)
    expect { service.apply_to(rows, reviewed: reviewed.map { |row| row.merge(amount: "8421.131", hours: "1e3") }, confirmed: true) }.to raise_error(ArgumentError, /valid/)
  end

  it "uses exact per-person amounts and additive saved-job hours, preserving workbook money" do
    create(:payroll_item, company: company, employee: worker, pay_period: period, hours_worked: 2, overtime_hours: 1)
    result = service.apply_to(rows, reviewed: reviewed, confirmed: true)
    expect(result.first[:period_pay]).to eq("8421.13")
    expect(result.first[:period_pay_evidence]).to include(source_type: "client_submission", submission_id: submission.id)
    expect(result.last).to include(loan_deduction: 219.70, total_tips: 3,
      client_extra_hours: { hours: "68", employee_wage_rate_id: rate.id, rate: "35.0" })
    expect(PayrollItem.where(employee: owner)).to be_empty
  end

  it "lets staff edit values and adds extra hours to Revel instead of the worksheet" do
    rows.last.merge!(workbook_only: false, regular_hours: 5, overtime_hours: 2)
    result = service.apply_to(rows, reviewed: [ { change_index: 0, amount: "8421.12" }, { change_index: 1, hours: "3.5" } ], confirmed: true)
    expect(result.first[:period_pay]).to eq("8421.12")
    expect(result.last).to include(regular_hours: 5, overtime_hours: 2, client_extra_hours: { hours: "3.5", employee_wage_rate_id: rate.id, rate: "35.0" })
  end

  it "refuses changed or missing rates, inactive employees and excluded retained source rows" do
    rate.update!(rate: 36)
    expect(service.proposals.last[:error]).to include("changed")
    expect { service.apply_to(rows, reviewed: reviewed, confirmed: true) }.to raise_error(ArgumentError, /changed/)
    rate.update!(rate: 35)
    worker.update!(status: "terminated", termination_date: period.start_date - 1)
    expect(service.proposals.last[:error]).to include("terminated")
    worker.update!(status: "active", termination_date: nil)
    expect { service.apply_to(rows.first(1), reviewed: reviewed, confirmed: true, source_employee_ids: [ owner.id, worker.id ]) }.to raise_error(ArgumentError, /included/)
    rate.destroy!
    expect(service.proposals.last[:error]).to include("missing")
  end

  it "includes an employee absent from both files without guessing a job" do
    result = service.apply_to(rows.first(1), reviewed: reviewed, confirmed: true, source_employee_ids: [ owner.id ])
    expect(result.last).to include(employee_id: worker.id, client_extra_hours: { hours: "68", employee_wage_rate_id: rate.id, rate: "35.0" })
  end
  context "legacy revisions" do
    let(:changes) { [ { kind: "owner_pay", amount: "1200", basis: "each", note: "Both owners" }, { kind: "extra_hours", employee_id: worker.id, hours: "5" } ] }

    it "keeps legacy instructions readable for manual review without guessing a person, split or saved job" do
      expect(service.proposals).to eq([])
      expect(service.manual_review_warnings.join).to include("total/each", "no job or rate is inferred")
      expect(service.apply_to(rows, reviewed: [], confirmed: false)).to eq(rows)
      expect(period.payroll_items.count).to eq(0)
    end
  end
end
