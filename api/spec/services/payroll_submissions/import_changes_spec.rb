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
    [ { kind: "owner_pay", employee_id: owner.id, amount: "4500.00" },
      { kind: "extra_hours", employee_id: worker.id, employee_wage_rate_id: rate.id, wage_rate: "35.0", hours: "68" } ]
  end
  let(:service) { described_class.new(submission: submission, pay_period: period) }
  let(:reviewed) { [ { change_index: 0, amount: "4500.00" }, { change_index: 1, hours: "68" } ] }
  let(:rows) { [ { employee_id: owner.id, workbook_only: true }, { employee_id: worker.id, workbook_only: true, loan_deduction: 200.00, total_tips: 3 } ] }

  it "does not write on preview and requires explicit complete confirmation" do
    expect { service.proposals }.not_to change(PayrollItem, :count)
    expect(service.proposals.first).to include(amount: "4500.00", employee_id: owner.id)
    expect { service.apply_to(rows, reviewed: reviewed, confirmed: false) }.to raise_error(ArgumentError, /Confirm/)
    expect { service.apply_to(rows, reviewed: reviewed.first(1), confirmed: true) }.to raise_error(ArgumentError, /every/)
    expect { service.apply_to(rows, reviewed: reviewed.map { |row| row.merge(amount: "4500.001", hours: "1e3") }, confirmed: true) }.to raise_error(ArgumentError, /valid/)
  end

  it "uses exact per-person amounts and additive saved-job hours, preserving workbook money" do
    create(:payroll_item, company: company, employee: worker, pay_period: period, hours_worked: 2, overtime_hours: 1)
    result = service.apply_to(rows, reviewed: reviewed, confirmed: true)
    expect(result.first[:period_pay]).to eq("4500.00")
    expect(result.first[:period_pay_evidence]).to include(source_type: "client_submission", submission_id: submission.id)
    expect(result.last).to include(loan_deduction: 200.00, total_tips: 3,
      client_extra_hours: { hours: "68", employee_wage_rate_id: rate.id, rate: "35.0" })
    expect(PayrollItem.where(employee: owner)).to be_empty
  end

  it "lets staff edit values and adds extra hours to Revel instead of the worksheet" do
    rows.last.merge!(workbook_only: false, regular_hours: 5, overtime_hours: 2)
    result = service.apply_to(rows, reviewed: [ { change_index: 0, amount: "4495.00" }, { change_index: 1, hours: "3.5" } ], confirmed: true)
    expect(result.first[:period_pay]).to eq("4495.00")
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
  it "shows baseline hours on reimport rather than the previously applied total" do
    create(:payroll_item, company: company, employee: worker, pay_period: period, hours_worked: 70,
      custom_columns_data: { client_change_evidence: { kind: "extra_hours", submission_id: submission.id,
        baseline_regular_hours: "2.0", applied_regular_hours: "70.0" } })
    expect(service.proposals.last[:saved_regular_hours]).to eq("2.0")
  end

  it "takes a corrected workbook's owner pay instead of requiring a new decision when the client drops owner pay" do
    create(:payroll_item, company: company, employee: owner, pay_period: period, salary_override: 4500.00,
      custom_columns_data: { client_change_evidence: { kind: "owner_pay", submission_id: submission.id + 1 },
        period_pay_evidence: { source_type: "client_submission" } })
    submission.update_columns(change_rows: [])
    expect(service.proposals(source_rows: [ { employee_id: owner.id } ])).to contain_exactly(include(employee_id: owner.id, requires_pay_decision: true))
    workbook_rows = [ { employee_id: owner.id, period_pay: "5000" } ]
    expect(service.proposals(source_rows: workbook_rows)).to be_empty
    expect(service.apply_to(workbook_rows, reviewed: [], confirmed: false).sole).to include(period_pay: "5000")
    expect { described_class.new(submission: submission, pay_period: period).apply_to([], reviewed: [], confirmed: true, source_employee_ids: [ owner.id ]) }
      .to raise_error(ArgumentError, /include .+ file row instead of deferring/)
  end

  it "requires a choice before replacing saved owner pay" do
    create(:payroll_item, company: company, employee: owner, pay_period: period, salary_override: 5000)
    expect(service.proposals.first).to include(saved_period_pay: "5000.0", pay_conflict: true)
    expect { service.apply_to(rows, reviewed: reviewed, confirmed: true) }.to raise_error(ArgumentError, /Choose.*pay/)
    input = reviewed.deep_dup
    input.first.merge!(pay_choice: "saved", saved_period_pay: "5000.0")
    expect(service.apply_to(rows, reviewed: input, confirmed: true).first[:period_pay]).to be_nil
  end

  it "requires a choice between workbook and client owner pay" do
    rows.first.merge!(period_pay: "4000", period_pay_evidence: { source: "Workbook" })
    expect { service.apply_to(rows, reviewed: reviewed, confirmed: true) }.to raise_error(ArgumentError, /Choose.*pay/)
    input = reviewed.deep_dup
    input.first.merge!(pay_choice: "workbook", workbook_period_pay: "4000")
    expect(service.apply_to(rows, reviewed: input, confirmed: true).first).to include(period_pay: "4000", period_pay_evidence: { source: "Workbook" })
    expect(service.review_decisions.first).to include(pay_choice: "workbook", applied_value: "4000", reviewed_value: "4500.00")
  end

  it "lets staff decline an invalid row with a required reason" do
    worker.update!(status: "inactive")
    input = reviewed.deep_dup
    input.last.merge!(decision: "decline", reason: "Not working this period")
    expect(service.apply_to(rows.first(1), reviewed: input, confirmed: true).sole[:period_pay]).to eq("4500.00")
    expect(service.review_decisions.last).to include(decision: "decline", reason: "Not working this period", employee_id: worker.id)
    input.last[:reason] = " "
    expect { service.apply_to(rows.first(1), reviewed: input, confirmed: true) }.to raise_error(ArgumentError, /reason/)
  end

  it "supports preloaded active wage rates" do
    worker.employee_wage_rates.load
    allow(Employee).to receive(:find_by).with(company_id: company.id, id: worker.id).and_return(worker)
    allow(Employee).to receive(:find_by).with(company_id: company.id, id: owner.id).and_return(owner)
    expect(service.proposals.last[:error]).to be_nil
  end

  it "normalizes extra hours with preloaded employee rates" do
    worker.employee_wage_rates.load
    allow(Employee).to receive(:where).with(company_id: company.id, id: [ worker.id ]).and_return([ worker ])
    result = PayrollSubmissions::ChangeRows.normalize!([ changes.last ], company_id: company.id)
    expect(result.sole).to include("employee_wage_rate_id" => rate.id, "hours" => "68")
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
