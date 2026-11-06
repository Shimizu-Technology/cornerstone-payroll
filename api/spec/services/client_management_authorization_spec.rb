# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client management service authorization" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, role: "accountant") }
  let(:admin) { create(:user, company: company) }
  let!(:assignment) { create(:company_assignment, user: actor, company: company, granted_by: admin, client_management: true) }

  it "allows historical worker mapping and rejects a subsequent revoked grant on the same actor" do
    batch = create(:historical_import_batch, company: company)
    worker = create(:historical_worker, company: company, historical_import_batch: batch)
    QuickbooksHistory::MappingService.new(worker: worker, employee: nil, archive_only: true, actor: actor).call
    expect(worker.reload.mapping_status).to eq("archive_only")
    assignment.update!(client_management: false)
    expect do
      QuickbooksHistory::MappingService.new(worker: worker, employee: nil, archive_only: true, actor: actor).call
    end.to raise_error(ArgumentError, /company access/)
  end

  it "does not apply the grant to another company's historical bootstrap" do
    other = create(:company, organization: company.organization)
    expect do
      QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: other.id)
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized)
  end

  it "rechecks the grant in direct configuration services" do
    assignment.update!(client_management: false)
    expect do
      CompanyPayScheduleChangeService.call!(company: company, actor: actor, effective_on: Date.current,
        schedule_attributes: {}, workweek_attributes: {})
    end.to raise_error(CompanyPayScheduleChangeService::ChangeError, /access required/)
    employee = create(:employee, company: company)
    expect do
      EmployeeWorkProfileChangeService.call!(employee: employee, actor: actor, attributes: { effective_on: Date.current })
    end.to raise_error(EmployeeWorkProfileChangeService::Error, /access required/)
    expect do
      EmployeeRetirementElectionChangeService.new(employee: employee, actor: actor, attributes: {}, source: "staff", reason: "Revoked grant").call!
    end.to raise_error(EmployeeRetirementElectionChangeService::Error, /access required/)
    expect do
      EmployeeStatusTransitionService.terminate!(employee: employee, actor: actor, attributes: { effective_date: Date.current })
    end.to raise_error(EmployeeStatusTransitionService::Error, /access required/)
  end
end
