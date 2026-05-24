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

    it "keeps a stable employee order instead of re-sorting by edited check number" do
      item_a.update!(check_number: "9999")

      get "/api/v1/admin/pay_periods/#{pay_period.id}/checks"

      names = response.parsed_body["checks"].map { |check| check["employee_name"] }
      expect(names).to eq([ "Alice Reyes", "Bob Santos" ])
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
    it "returns a combined PDF when check merging is available" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/batch_pdf"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
    end

    it "returns 422 for draft periods" do
      post "/api/v1/admin/pay_periods/#{draft_period.id}/checks/batch_pdf"
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "logs batch_downloaded events for each printable check" do
      expect {
        post "/api/v1/admin/pay_periods/#{pay_period.id}/checks/batch_pdf"
      }.to change { CheckEvent.where(event_type: "batch_downloaded").count }.by(2)
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

    it "returns 422 for an uncommitted pay period" do
      get "/api/v1/admin/payroll_items/#{draft_item.id}/check"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/committed pay periods/)
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
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check — stop payment requested" }
      expect(response).to have_http_status(:created)
      json = response.parsed_body
      expect(json["original_check_number"]).to eq("3000")
      expect(json["reprint"]).to be_present
    end

    it "does NOT void the payroll item (payroll obligation stays active)" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      expect(item_a.reload.voided).to be false
    end

    it "assigns a new check number from the sequence" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      expect(item_a.reload.check_number).to eq("3002")
    end

    it "stores reprint_of_check_number on the item" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      expect(item_a.reload.reprint_of_check_number).to eq("3000")
    end

    it "clears check_printed_at so item is ready for printing again" do
      item_a.mark_printed!(user: admin_user)
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Damaged check stock" }
      expect(item_a.reload.check_printed_at).to be_nil
    end

    it "advances the company next_check_number" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      expect(company.reload.next_check_number).to eq(3003)
    end

    it "creates a reprinted check_event" do
      expect {
        post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      }.to change { CheckEvent.where(event_type: "reprinted").count }.by(1)
    end

    it "creates a voided check_event for the old check number" do
      expect {
        post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check — stop payment requested" }
      }.to change { CheckEvent.where(event_type: "voided", check_number: "3000").count }.by(1)
      expect(CheckEvent.where(event_type: "voided", check_number: "3000").last.reason).to eq("Lost check — stop payment requested")
    end

    it "returns 422 when the reissue reason is blank" do
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("A reason is required to reissue a check")
    end

    it "returns 422 when reprinting an already-voided check" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: "Was already voided before test")
      post "/api/v1/admin/payroll_items/#{item_a.id}/reprint", params: { reason: "Lost check" }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # -----------------------------------------------------------------------
  # PATCH /payroll_items/:id/check_number
  # Corrects an already-assigned check number and syncs report drafts.
  # -----------------------------------------------------------------------
  describe "PATCH /api/v1/admin/payroll_items/:payroll_item_id/check_number" do
    it "updates the payroll item check number" do
      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "3010", reason: "Actual physical check stock used" }

      expect(response).to have_http_status(:ok)
      expect(item_a.reload.check_number).to eq("3010")
    end

    it "records a renumbered audit event" do
      expect {
        patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
          params: { check_number: "3010", reason: "Actual physical check stock used" }
      }.to change { CheckEvent.where(event_type: "renumbered").count }.by(1)

      event = CheckEvent.where(event_type: "renumbered").last
      expect(event.check_number).to eq("3010")
      expect(event.reason).to include("3000")
    end

    it "advances next_check_number when the corrected number is ahead of the sequence" do
      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "4000", reason: "Loaded a higher-numbered check sheet" }

      expect(company.reload.next_check_number).to eq(4001)
    end

    it "rejects duplicate payroll check numbers" do
      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: item_b.check_number }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("already used")
      expect(item_a.reload.check_number).to eq("3000")
    end

    it "rejects numbers already used by non-employee checks" do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        payable_to: "Treasurer of Guam",
        check_type: "tax_deposit",
        amount: 50.52,
        check_number: "3500"
      )

      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "3500" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("non-employee check")
    end

    it "syncs saved transmittal and check sign-off sheet entries" do
      Transmittal.create!(
        pay_period: pay_period,
        company: company,
        check_number_first: "2019",
        check_number_last: "2026",
        non_employee_check_numbers: {}
      )
      non_employee_check = NonEmployeeCheck.create!(
        pay_period: pay_period,
        company: company,
        payable_to: "Treasurer of Guam",
        amount: 50.52,
        check_type: "tax_deposit",
        check_number: "3011"
      )
      CheckSignoffSheet.create!(
        pay_period: pay_period,
        company: company,
        entries: [
          { name: "Reyes, Alice", check_number: "3000" },
          { name: "Santos, Bob", check_number: "3001" }
        ]
      )

      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "3010", reason: "Corrected after print test" }

      expect(response).to have_http_status(:ok)
      expect(pay_period.transmittal.reload.check_number_first).to eq("3001")
      expect(pay_period.transmittal.check_number_last).to eq("3011")
      expect(pay_period.transmittal.non_employee_check_numbers[non_employee_check.id.to_s]).to eq("3011")
      synced_entry = pay_period.check_signoff_sheet.reload.entries.find { |entry| entry["name"] == "Reyes, Alice" }
      expect(synced_entry["check_number"]).to eq("3010")
    end

    it "only syncs the matching sign-off row when names repeat" do
      CheckSignoffSheet.create!(
        pay_period: pay_period,
        company: company,
        entries: [
          { name: "Reyes, Alice", check_number: "3000" },
          { name: "Reyes, Alice", check_number: "3999" },
          { name: "Someone Else", check_number: "3000" }
        ]
      )

      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "3010", reason: "Corrected after print test" }

      expect(response).to have_http_status(:ok)
      entries = pay_period.check_signoff_sheet.reload.entries
      expect(entries).to include({ "name" => "Reyes, Alice", "check_number" => "3010" })
      expect(entries).to include({ "name" => "Reyes, Alice", "check_number" => "3999" })
      expect(entries).to include({ "name" => "Someone Else", "check_number" => "3000" })
    end

    it "returns 422 for non-numeric check numbers" do
      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "ABC123" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("numeric")
    end

    it "returns 422 for voided checks" do
      item_a.update!(voided: true, voided_at: Time.current, void_reason: "Already voided before correction")

      patch "/api/v1/admin/payroll_items/#{item_a.id}/check_number",
        params: { check_number: "3010" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("voided")
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
      expect(json).to include(
        "next_check_number",
        "check_stock_type",
        "check_offset_x",
        "check_offset_y",
        "check_layout_config",
        "active_printer_profile_id",
        "active_printer_profile_name"
      )
    end

    it "includes the active printer profile when one is selected" do
      profile = PrinterProfile.create!(
        organization: company.organization,
        name: "Front Desk Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      company.update!(active_printer_profile: profile)

      get "/api/v1/admin/companies/check_settings"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body.fetch("check_settings")
      expect(json.fetch("active_printer_profile_id")).to eq(profile.id)
      expect(json.fetch("active_printer_profile_name")).to eq("Front Desk Printer")
    end
  end

  describe "GET /api/v1/admin/companies/check_layout" do
    it "returns the resolved layout used by the check PDF generator" do
      company.update!(
        check_offset_x: 0.125,
        check_offset_y: -0.025,
        check_layout_config: {
          check_face: {
            date: { x: 481.5 }
          }
        }
      )

      get "/api/v1/admin/companies/check_layout"

      expect(response).to have_http_status(:ok)
      layout = response.parsed_body.fetch("check_layout")

      expect(layout).to include("check_stock_type" => "bottom_check")
      expect(layout).to include("default_layout_config", "resolved_layout_config", "page")
      expect(layout.dig("resolved_layout_config", "check_face", "date", "x")).to eq(481.5)
      expect(layout.dig("resolved_layout_config", "check_face", "amount", "x")).to eq(CheckGenerator.default_layout_config.dig("check_face", "amount", "x"))
      expect(layout.dig("page", "check_section_bottom")).to eq(0)
      expect(layout.dig("page", "offset_x_points")).to be_within(0.001).of(9.0)
    end

    it "returns First Hawaiian 4-up layout metadata for 4-up stock" do
      company.update!(check_stock_type: "first_hawaiian_4up")

      get "/api/v1/admin/companies/check_layout"

      expect(response).to have_http_status(:ok)
      layout = response.parsed_body.fetch("check_layout")

      expect(layout.fetch("check_stock_type")).to eq("first_hawaiian_4up")
      expect(layout.dig("resolved_layout_config", "register", "payee", "x")).to be_present
      expect(layout.dig("page", "slot_count")).to eq(4)
    end

    it "can preview a selected stock type without saving the company" do
      company.update!(check_stock_type: "bottom_check")

      get "/api/v1/admin/companies/check_layout", params: { check_stock_type: "first_hawaiian_4up" }

      expect(response).to have_http_status(:ok)
      layout = response.parsed_body.fetch("check_layout")
      expect(layout.fetch("check_stock_type")).to eq("first_hawaiian_4up")
      expect(layout.dig("page", "slot_count")).to eq(4)
      expect(company.reload.check_stock_type).to eq("bottom_check")
    end
  end

  describe "POST /api/v1/admin/companies/test_check_pdf" do
    it "renders a payroll test PDF from draft settings without saving them" do
      company.update!(
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0,
        check_layout_config: {}
      )

      post "/api/v1/admin/companies/test_check_pdf",
        params: {
          sample_type: "payroll",
          check_settings: {
            check_stock_type: "top_check",
            check_offset_x: 0.25,
            check_offset_y: -0.125,
            bank_name: "Draft Bank",
            bank_address: "Draft Bank Address",
            check_memo_template: "Draft memo",
            check_layout_config: {
              check_face: {
                payee: { x: 72.5 }
              }
            }
          }
        }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.body).to start_with("%PDF")

      company.reload
      expect(company.check_stock_type).to eq("bottom_check")
      expect(company.check_offset_x.to_f).to eq(0.0)
      expect(company.check_offset_y.to_f).to eq(0.0)
      expect(company.bank_name).not_to eq("Draft Bank")
      expect(company.check_layout_config).to eq({})
    end

    it "renders non-employee test PDFs from draft settings without saving them" do
      post "/api/v1/admin/companies/test_check_pdf",
        params: {
          sample_type: "grt",
          check_settings: {
            check_stock_type: "bottom_check",
            check_offset_x: 0.1,
            check_offset_y: 0.2,
            check_layout_config: {
              check_face: {
                memo: { x: 48.0, width: 300.0 }
              }
            }
          }
        }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.body).to start_with("%PDF")
      expect(company.reload.check_layout_config).to eq({})
    end

    it "rejects unknown test check types" do
      post "/api/v1/admin/companies/test_check_pdf",
        params: { sample_type: "unknown", check_settings: {} }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Unknown test check type")
    end
  end

  describe "PATCH /api/v1/admin/companies/check_settings" do
    it "updates offset, stock type, and layout overrides" do
      profile = PrinterProfile.create!(
        organization: company.organization,
        name: "Saved Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0
      )
      company.update!(active_printer_profile: profile)

      patch "/api/v1/admin/companies/check_settings",
        params: {
          check_offset_x: 0.1,
          check_offset_y: -0.05,
          check_stock_type: "top_check",
          check_layout_config: {
            check_face: {
              date: { x: 480.0 }
            }
          }
        }
      expect(response).to have_http_status(:ok)
      expect(company.reload.check_offset_x).to be_within(0.001).of(0.1)
      expect(company.reload.check_stock_type).to eq("top_check")
      expect(company.reload.check_layout_config.dig("check_face", "date", "x")).to eq(480.0)
      expect(company.active_printer_profile_id).to be_nil
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_id")).to be_nil
    end

    it "keeps the active printer profile when saving unrelated settings" do
      profile = PrinterProfile.create!(
        organization: company.organization,
        name: "Saved Printer",
        check_stock_type: "bottom_check",
        check_offset_x: 0,
        check_offset_y: 0,
        check_layout_config: {}
      )
      company.update!(
        active_printer_profile: profile,
        check_stock_type: profile.check_stock_type,
        check_offset_x: profile.check_offset_x,
        check_offset_y: profile.check_offset_y,
        check_layout_config: profile.check_layout_config
      )

      patch "/api/v1/admin/companies/check_settings",
        params: {
          check_offset_x: "0.000",
          check_offset_y: "0.000",
          check_stock_type: "bottom_check",
          check_layout_config: {},
          bank_name: "Bank of Guam",
          auto_create_fit_check: true
        }

      expect(response).to have_http_status(:ok)
      expect(company.reload.active_printer_profile_id).to eq(profile.id)
      expect(response.parsed_body.dig("check_settings", "active_printer_profile_id")).to eq(profile.id)
    end

    it "allows accountants to update check settings for their assigned companies" do
      accountant_user = User.create!(
        company: company,
        email: "checks-accountant@example.com",
        name: "Checks Accountant",
        role: "accountant",
        active: true
      )
      CompanyAssignment.create!(user: accountant_user, company: company)
      allow_any_instance_of(Api::V1::Admin::ChecksController).to receive(:current_user).and_return(accountant_user)

      patch "/api/v1/admin/companies/check_settings",
        params: {
          check_offset_x: 0.1
        }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["check_settings"]).to be_present
    end
  end

  describe "PATCH /api/v1/admin/companies/next_check_number" do
    it "rejects a number that is already in the issued check range" do
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 3001 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("highest issued check number")
    end

    it "rejects moving backward into an unissued range below the current next number" do
      company.update!(next_check_number: 5000)

      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 4000 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("cannot move backward")
    end

    it "allows moving the next check number forward after checks exist" do
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 4000 }
      expect(response).to have_http_status(:ok)
      expect(company.reload.next_check_number).to eq(4000)
    end

    it "ignores non-numeric historical check numbers when finding the highest issued number" do
      item_a.update!(check_number: "VOID-3000")

      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 4000 }

      expect(response).to have_http_status(:ok)
      expect(company.reload.next_check_number).to eq(4000)
    end

    it "rejects a value less than 1" do
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 0 }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects values above the integer safety bound" do
      patch "/api/v1/admin/companies/next_check_number", params: { next_check_number: 10_000_000 }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("cannot exceed")
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
