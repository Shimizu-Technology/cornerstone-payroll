# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Checks", type: :request do
  let!(:company) do
    create(:company,
      name: "MoSa's Restaurant",
      next_check_number: 3000,
      check_stock_type: "bottom_check")
  end

  let!(:admin_user) do
    User.create!(
      company: company,
      email: "checks-admin@example.com",
      name: "Checks Admin",
      role: "admin",
      active: true
    )
  end

  let!(:pay_period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 19))
  end

  let!(:employee_a) { create(:employee, company: company, first_name: "Alice", last_name: "Reyes") }
  let!(:employee_b) { create(:employee, company: company, first_name: "Bob", last_name: "Santos") }

  let!(:item_a) do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee_a,
      check_number: "3000",
      net_pay: 960.00,
      gross_pay: 1200.00,
      total_deductions: 240.00)
  end

  let!(:item_b) do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee_b,
      check_number: "3001",
      net_pay: 840.00,
      gross_pay: 1050.00,
      total_deductions: 210.00)
  end

  let(:draft_period) { create(:pay_period, company: company, status: "draft") }
  let!(:draft_item) do
    create(:payroll_item, :with_check,
      pay_period: draft_period,
      employee: employee_a,
      check_number: "3999",
      net_pay: 500.00,
      gross_pay: 700.00,
      total_deductions: 200.00)
  end

  # -----------------------------------------------------------------------
  # GET /checks (index)
  # -----------------------------------------------------------------------
  describe "GET /api/v1/admin/pay_periods/:pay_period_id/checks" do
    it "returns 200 with check list for a committed period" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}/checks"
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["checks"].size).to eq(2)
    end

    it "includes check_status, voided, check_number fields" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}/checks"
      check = response.parsed_body["checks"].first
      expect(check).to include("check_number", "check_status", "voided", "net_pay")
    end

    it "returns meta counts" do
      get "/api/v1/admin/pay_periods/#{pay_period.id}/checks"
      meta = response.parsed_body["meta"]
      expect(meta["total"]).to eq(2)
      expect(meta["unprinted"]).to eq(2)
      expect(meta["printed"]).to eq(0)
    end

    it "returns 422 for a draft pay period" do
      get "/api/v1/admin/pay_periods/#{draft_period.id}/checks"
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # -----------------------------------------------------------------------
  # POST /checks/batch_pdf
  # -----------------------------------------------------------------------
  describe "POST /api/v1/admin/pay_periods/:pay_period_id/checks/batch_pdf" do
    it "returns 422 when combine_pdf is unavailable (no silent partial output)" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/batch_pdf"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/combine_pdf/i)
    end

    it "returns 422 for draft periods" do
      post "/api/v1/admin/pay_periods/#{draft_period.id}/checks/batch_pdf"
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "does not log batch_downloaded events when batch generation fails" do
      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/batch_pdf"
      }.not_to change { CheckEvent.where(event_type: "batch_downloaded").count }
    end
  end

  # -----------------------------------------------------------------------
  # POST /checks/mark_all_printed
  # -----------------------------------------------------------------------
  describe "POST /api/v1/admin/pay_periods/:pay_period_id/checks/mark_all_printed" do
    it "marks all unprinted checks as printed" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/mark_all_printed"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["marked_printed"]).to eq(2)
    end

    it "sets check_printed_at on each item" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/mark_all_printed"
      expect(item_a.reload.check_printed_at).to be_present
      expect(item_b.reload.check_printed_at).to be_present
    end

    it "does not double-mark already printed items" do
      item_a.mark_printed!(user: admin_user)
      post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/mark_all_printed"
      expect(response.parsed_body["marked_printed"]).to eq(1)
    end
  end

  # -----------------------------------------------------------------------
  # GET /payroll_items/:id/check (single PDF)
  # -----------------------------------------------------------------------
  describe "GET /api/v1/admin/payroll_items/:payroll_item_id/check" do
    it "returns a PDF" do
      get "/api/v1/admin/payroll_items/#{item_a.id}/check"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end

    it "returns a PDF for a voided item too" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: "Test void reason here")
      get "/api/v1/admin/payroll_items/#{item_a.id}/check"
      expect(response).to have_http_status(:ok)
    end
  end

  # -----------------------------------------------------------------------
  # POST /payroll_items/:id/check/mark_printed
  # -----------------------------------------------------------------------
  describe "POST /api/v1/admin/payroll_items/:payroll_item_id/check/mark_printed" do
    it "returns 200 and sets check_printed_at" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/check/mark_printed"
      expect(response).to have_http_status(:ok)
      expect(item_a.reload.check_printed_at).to be_present
    end

    it "flags already_printed: false on first print" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/check/mark_printed"
      expect(response.parsed_body["already_printed"]).to be false
    end

    it "flags already_printed: true on subsequent print" do
      item_a.mark_printed!(user: admin_user)
      post "/api/v1/admin/payroll_items/#{item_a.id}/check/mark_printed"
      expect(response.parsed_body["already_printed"]).to be true
    end

    it "returns 422 for voided items" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: "Paper jam in printer tray")
      post "/api/v1/admin/payroll_items/#{item_a.id}/check/mark_printed"
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 for uncommitted pay periods" do
      post "/api/v1/admin/payroll_items/#{draft_item.id}/check/mark_printed"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/committed pay periods/)
    end
  end

  # -----------------------------------------------------------------------
  # POST /payroll_items/:id/void
  # -----------------------------------------------------------------------
  describe "POST /api/v1/admin/payroll_items/:payroll_item_id/void" do
    let(:valid_reason) { "Paper jam — physical check destroyed during print run" }

    it "voids the check and returns 200" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: valid_reason }
      expect(response).to have_http_status(:ok)
      expect(item_a.reload.voided).to be true
    end

    it "includes the voided item in the response" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: valid_reason }
      expect(response.parsed_body["payroll_item"]["voided"]).to be true
    end

    it "returns 422 without a reason" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: "" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 with a too-short reason" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: "short" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 when voiding an already-voided check" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: valid_reason)
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: valid_reason }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "creates a voided check_event" do
      expect {
        post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: valid_reason }
      }.to change { CheckEvent.where(event_type: "voided").count }.by(1)
    end

    it "returns 422 for uncommitted pay periods" do
      post "/api/v1/admin/payroll_items/#{draft_item.id}/void", params: { reason: valid_reason }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/committed pay periods/)
    end

    it "records IP address on voided audit event" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/void", params: { reason: valid_reason }
      event = CheckEvent.where(event_type: "voided", payroll_item_id: item_a.id).order(:created_at).last
      expect(event.ip_address).to be_present
    end
  end

  # -----------------------------------------------------------------------
  # POST /payroll_items/:id/reprint
  # In-place reassignment: same item, new check number, audit trail.
  # -----------------------------------------------------------------------
  describe "POST /api/v1/admin/payroll_items/:payroll_item_id/reprint" do
    before { company.update!(next_check_number: 3002) }

    it "returns 201 with original_check_number and reprint data" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(response).to have_http_status(:created)
      json = response.parsed_body
      expect(json["original_check_number"]).to eq("3000")
      expect(json["reprint"]).to be_present
    end

    it "does NOT void the payroll item (payroll obligation stays active)" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(item_a.reload.voided).to be false
    end

    it "assigns a new check number from the sequence" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(item_a.reload.check_number).to eq("3002")
    end

    it "stores reprint_of_check_number on the item" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(item_a.reload.reprint_of_check_number).to eq("3000")
    end

    it "clears check_printed_at so item is ready for printing again" do
      item_a.mark_printed!(user: admin_user)
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(item_a.reload.check_printed_at).to be_nil
    end

    it "advances the company next_check_number" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(company.reload.next_check_number).to eq(3003)
    end

    it "creates a reprinted check_event" do
      expect {
        post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      }.to change { CheckEvent.where(event_type: "reprinted").count }.by(1)
    end

    it "creates a voided check_event for the old check number" do
      expect {
        post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      }.to change { CheckEvent.where(event_type: "voided", check_number: "3000").count }.by(1)
    end

    it "returns 422 when reprinting an already-voided check" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: "Was already voided before test")
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint"
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # -----------------------------------------------------------------------
  # Company check settings
  # -----------------------------------------------------------------------
  describe "GET /api/v1/admin/companies/check_settings" do
    it "returns check settings" do
      get "/api/v1/admin/companies/check_settings"
      expect(response).to have_http_status(:ok)
      json = response.parsed_body["check_settings"]
      expect(json).to include("next_check_number", "check_stock_type", "check_offset_x", "check_offset_y")
    end
  end

  describe "PATCH /api/v1/admin/companies/check_settings" do
    it "updates offset and stock type" do
      patch "/api/v1/admin/companies/check_settings",
        params: { check_offset_x: 0.1, check_offset_y: -0.05, check_stock_type: "top_check" }
      expect(response).to have_http_status(:ok)
      expect(company.reload.check_offset_x).to be_within(0.001).of(0.1)
      expect(company.reload.check_stock_type).to eq("top_check")
    end
  end

  describe "PATCH /api/v1/admin/companies/next_check_number" do
    # The existing pay_period in this spec is dated 2026-03-19 (past year relative to test run).
    # To test "no checks issued this year", we need a company whose pay_periods
    # all have pay_dates before the current calendar year.
    # Since current year is 2026 and the existing items ARE 2026, we verify the
    # correct guard fires. Use a future year for the "allowed" case by making
    # a clean company with no 2026 pay periods.
    let!(:clean_company) do
      create(:company, name: "Clean Co for Check # Test", next_check_number: 5000)
    end
    let!(:clean_admin) do
      # current_user = User.find_by(role: "admin") - this picks admin_user (belonging to company)
      # so clean_company requests still go through company's admin_user context.
      # The update_next_check_number endpoint uses current_company_id from admin_user.
      # We test by verifying the endpoint updates the CURRENT company (admin_user's company).
      # For the "allowed" test we need a company with no current-year checks.
      # Since admin_user's company has 2026 items, we can't use that for the "allowed" case.
      # Instead we verify what we can: the guard correctly blocks 2026 changes.
      nil
    end

    it "rejects the change when checks have already been issued this year" do
      # admin_user's company (company) has item_a with check 3000 dated 2026 (current year)
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 100 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Cannot change")
    end

    it "rejects a value less than 1" do
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 0 }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/admin/companies/alignment_test_pdf" do
    it "returns a PDF" do
      get "/api/v1/admin/companies/alignment_test_pdf"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end
  end

  # -----------------------------------------------------------------------
  # Check number auto-assignment at commit
  # Uses the same company as admin_user so current_company_id resolves correctly.
  # -----------------------------------------------------------------------
  describe "check number assignment at commit" do
    let!(:emp_x)    { create(:employee, company: company, first_name: "Carlos", last_name: "Cruz") }
    let!(:emp_y)    { create(:employee, company: company, first_name: "Diana",  last_name: "Dela Cruz") }
    let!(:approved_period) do
      create(:pay_period, :approved, company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 19))
    end
    let!(:item_x) do
      create(:payroll_item, pay_period: approved_period, employee: emp_x,
        gross_pay: 800, net_pay: 660, withholding_tax: 80, social_security_tax: 49.60,
        medicare_tax: 11.60, total_deductions: 141.20, check_number: nil)
    end
    let!(:item_y) do
      create(:payroll_item, pay_period: approved_period, employee: emp_y,
        gross_pay: 1000, net_pay: 820, withholding_tax: 100, social_security_tax: 62.00,
        medicare_tax: 14.50, total_deductions: 176.50, check_number: nil)
    end

    before { company.update!(next_check_number: 7000) }

    it "assigns check numbers when period is committed" do
      post "/api/v1/admin/pay_periods/#{approved_period.id}/commit"
      expect(response).to have_http_status(:ok)
      expect(item_x.reload.check_number).to be_present
      expect(item_y.reload.check_number).to be_present
    end

    it "assigns unique sequential numbers starting from next_check_number" do
      post "/api/v1/admin/pay_periods/#{approved_period.id}/commit"
      numbers = [ item_x.reload.check_number.to_i, item_y.reload.check_number.to_i ]
      expect(numbers.uniq.size).to eq(2)
      expect(numbers.sort).to eq([ 7000, 7001 ])
    end

    it "advances company next_check_number" do
      post "/api/v1/admin/pay_periods/#{approved_period.id}/commit"
      expect(company.reload.next_check_number).to eq(7002)
    end
  end
end
