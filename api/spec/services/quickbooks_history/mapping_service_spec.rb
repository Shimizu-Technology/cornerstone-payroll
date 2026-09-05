# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::MappingService do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let!(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let!(:batch) do
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: admin).call.batch
  end
  let(:worker) { batch.historical_workers.find_by!(source_name: "Worker, Alice") }

  after { cleanup_quickbooks_history_uploads }

  it "requires an attributed manager or administrator with company access" do
    expect do
      described_class.new(worker: worker, employee: employee, actor: nil).call
    end.to raise_error(ArgumentError, /attributed manager or administrator/)
    expect do
      described_class.new(worker: worker, employee: employee, actor: accountant).call
    end.to raise_error(ArgumentError, /attributed manager or administrator/)

    expect(worker.reload.employee_id).to be_nil
  end

  it "maps the worker and its snapshots when an authorized operator performs the action" do
    described_class.new(worker: worker, employee: employee, actor: admin).call

    expect(worker.reload).to have_attributes(
      employee_id: employee.id,
      match_method: "manual",
      match_confidence: 1
    )
    expect(worker.historical_paychecks.distinct.pluck(:employee_id)).to eq([ employee.id ])
  end
end
