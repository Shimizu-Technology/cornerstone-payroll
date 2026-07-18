# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check-number worksheet", type: :request do
  let(:company) { create(:company, next_check_number: 3002) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:employee_a) { create(:employee, company: company, first_name: "Alice", last_name: "Reyes") }
  let(:employee_b) { create(:employee, company: company, first_name: "Ben", last_name: "Cruz") }
  let!(:item_a) { create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee_a, check_number: "3000") }
  let!(:item_b) { create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee_b, check_number: "3001") }
  let!(:non_employee_check) do
    create(:non_employee_check, company: company, pay_period: pay_period, payment_period_type: "pay_period", check_number: "3500")
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CheckNumbersController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CheckNumbersController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "saves a mixed worksheet atomically and supports swapping payroll numbers" do
    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        reason: "Reviewed physical check stock",
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3001" },
          { source_type: "payroll_item", source_id: item_b.id, check_number: "3000" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3600" }
        ]
      }
    }.to change { CheckEvent.where(event_type: "renumbered").count }.by(2)
      .and change { NonEmployeeCheckEdit.count }.by(1)
      .and change { AuditLog.where(action: [ "checks#check_number_updated", "non_employee_checks#updated" ]).count }.by(3)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated_count"]).to eq(3)
    expect(item_a.reload.check_number).to eq("3001")
    expect(item_b.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3600")
    expect(company.reload.next_check_number).to eq(3601)
    expect(response.parsed_body.dig("check_print_queue", "items").map { |row| row["check_number"] })
      .to include("3000", "3001", "3600")
  end

  it "rolls back every requested change when one number is already used outside the worksheet" do
    other_period = create(
      :pay_period,
      :committed,
      company: company,
      start_date: Date.new(2024, 2, 1),
      end_date: Date.new(2024, 2, 14),
      pay_date: Date.new(2024, 2, 16)
    )
    other_employee = create(:employee, company: company)
    create(:payroll_item, :with_check, company: company, pay_period: other_period, employee: other_employee, check_number: "3999")

    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3999" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("3999")
    expect(item_a.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3500")
  end

  it "rejects duplicate numbers inside the submitted worksheet" do
    patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
      changes: [
        { source_type: "payroll_item", source_id: item_a.id, check_number: "3100" },
        { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3100" }
      ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Check number 3100 is entered more than once")
    expect(item_a.reload.check_number).to eq("3000")
    expect(non_employee_check.reload.check_number).to eq("3500")
  end

  it "does not allow a blank payroll check number" do
    patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
      changes: [ { source_type: "payroll_item", source_id: item_a.id, check_number: "" } ]
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Check number is required")
    expect(item_a.reload.check_number).to eq("3000")
  end

  it "does not write history when the submitted worksheet has no effective changes" do
    expect {
      patch "/api/v1/admin/pay_periods/#{pay_period.id}/check_numbers", params: {
        changes: [
          { source_type: "payroll_item", source_id: item_a.id, check_number: "3000" },
          { source_type: "non_employee_check", source_id: non_employee_check.id, check_number: "3500" }
        ]
      }
    }.not_to change { AuditLog.count }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["updated_count"]).to eq(0)
    expect(CheckEvent.where(event_type: "renumbered")).to be_empty
    expect(NonEmployeeCheckEdit.all).to be_empty
  end
end
