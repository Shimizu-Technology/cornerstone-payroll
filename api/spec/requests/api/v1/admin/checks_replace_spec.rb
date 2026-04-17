# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Checks#replace_check", type: :request do
  let!(:tax_table) { create(:tax_table) }
  let(:company)    { create(:company, auto_create_fit_check: false, next_check_number: 1001) }
  let(:department) { create(:department, company: company) }
  let(:employee) do
    create(:employee, company: company, department: department,
                      pay_rate: 15.00, pay_frequency: "biweekly",
                      filing_status: "single", allowances: 0)
  end
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
                                    start_date: Date.new(2024, 1, 1),
                                    end_date:   Date.new(2024, 1, 14),
                                    pay_date:   Date.new(2024, 1, 19))
  end
  let!(:original_item) do
    item = pay_period.payroll_items.build(
      employee:        employee,
      company_id:      company.id,
      employment_type: "hourly",
      pay_rate:        15.00,
      hours_worked:    60
    )
    PayrollCalculator.for(employee, item).calculate
    item.save!
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
                    .add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024)
                   .add_payroll_item!(item)
    company.assign_check_numbers!([item])
    item.reload
  end
  let!(:admin_user) do
    User.create!(company: company, email: "replace-admin@example.com",
                 name: "Replace Admin", role: "admin", active: true)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_user_id).and_return(admin_user.id)
  end

  describe "POST /api/v1/admin/payroll_items/:id/replace_check_preview" do
    it "returns a delta preview with mode :in_place for an unprinted item" do
      post "/api/v1/admin/payroll_items/#{original_item.id}/replace_check_preview",
           params: { corrected_inputs: { hours_worked: 80 } },
           as:    :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["mode"]).to eq("in_place")
      expect(json["original"]["gross_pay"]).to be_within(0.01).of(900.00)
      expect(json["corrected"]["gross_pay"]).to be_within(0.01).of(1200.00)
      expect(json["meta"]["original_check_number"]).to eq(original_item.check_number)
      expect(json["meta"]["will_assign_new_check_number"]).to eq(false)
    end

    it "returns 422 with a clean message when the inputs are invalid for preview" do
      contractor = create(:employee, company: company, department: department,
                                     employment_type: "contractor")
      contractor_item = pay_period.payroll_items.create!(
        employee: contractor, company_id: company.id,
        employment_type: "contractor", pay_rate: 50.00, hours_worked: 10,
        gross_pay: 500.00, net_pay: 500.00,
        check_number: "9001"
      )

      post "/api/v1/admin/payroll_items/#{contractor_item.id}/replace_check_preview",
           params: { corrected_inputs: { hours_worked: 12 } },
           as:    :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/contractor/i)
    end
  end

  describe "POST /api/v1/admin/payroll_items/:id/replace_check" do
    it "applies the corrected values, keeps same check #, logs a `replaced` event" do
      original_check_number = original_item.check_number

      post "/api/v1/admin/payroll_items/#{original_item.id}/replace_check",
           params: {
             corrected_inputs: { hours_worked: 80 },
             reason:           "Client reported 80h not 60h"
           },
           as:    :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["payroll_item"]["check_number"]).to eq(original_check_number)
      expect(json["payroll_item"]["events"].map { |e| e["event_type"] }).to include("replaced")

      original_item.reload
      expect(original_item.gross_pay).to be_within(0.01).of(1200.00)
    end

    it "voids old check + assigns new one when the original was printed" do
      original_item.update!(check_printed_at: Time.current, check_print_count: 1)
      original_check_number = original_item.check_number
      next_check_number     = company.next_check_number

      post "/api/v1/admin/payroll_items/#{original_item.id}/replace_check",
           params: {
             corrected_inputs: { hours_worked: 80 },
             reason:           "Returned uncashed; corrected hours"
           },
           as:    :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["payroll_item"]["check_number"]).to eq(next_check_number.to_s)
      expect(json["payroll_item"]["replaced_check_number"]).to eq(original_check_number)
      events = json["payroll_item"]["events"].map { |e| e["event_type"] }
      expect(events).to include("voided", "replaced")
    end

    it "returns 422 when the reason is too short" do
      post "/api/v1/admin/payroll_items/#{original_item.id}/replace_check",
           params: { corrected_inputs: { hours_worked: 80 }, reason: "short" },
           as:    :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/Reason is required/)
    end

    it "returns 422 with a clear message when corrected inputs cause zero change" do
      post "/api/v1/admin/payroll_items/#{original_item.id}/replace_check",
           params: { corrected_inputs: { hours_worked: 60 }, reason: "no change at all" },
           as:    :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/No change/)
    end
  end
end
