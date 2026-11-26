# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Track B D-3 demo markers (emails, PDFs, employee branding)" do
  let(:organization) { create(:organization) }
  let(:live_company) { create(:company, organization: organization, name: "Live Harbor Cafe", ein: "66-1112223") }
  let(:demo_company) { create_live_demo_company(organization: organization, name: "Demo Sunset Grill", ein: "66-9998887") }

  def pdf_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")
  end

  def text_y_positions(bytes, substring)
    reader = PDF::Reader.new(StringIO.new(bytes))
    # Group text runs by baseline y (rounded to 0.5pt) so kerning splits
    # within one line reassemble into the exact rendered string.
    lines_by_y = reader.pages.first.runs.group_by { |run| (run.y * 2).round / 2.0 }
    lines_by_y.select { |_y, runs| runs.map(&:text).join.include?(substring) }.keys
  end

  def demo_footer_y_positions(bytes)
    text_y_positions(bytes, DemoPdfFooter::TEXT)
  end

  describe "email subject prefix" do
    let(:allowlisted) { "demo-reviewer@allowed.example" }

    around do |example|
      original_allowlist = ENV["DEMO_EMAIL_ALLOWLIST"]
      original_transport = ENV["PORTAL_EMAIL_TRANSPORT"]
      ENV["DEMO_EMAIL_ALLOWLIST"] = allowlisted
      ENV["PORTAL_EMAIL_TRANSPORT"] = "capture"
      PortalNotifications::Transport.clear_captured!
      example.run
    ensure
      ENV["DEMO_EMAIL_ALLOWLIST"] = original_allowlist
      ENV["PORTAL_EMAIL_TRANSPORT"] = original_transport
      PortalNotifications::Transport.clear_captured!
    end

    it "prefixes demo email subjects with [Demo] idempotently and leaves live emails unchanged" do
      demo_payload = DemoOutbound.scoped(demo_company) do
        DemoOutbound.filter_payload(to: [ allowlisted ], subject: "Payroll reminder")
      end
      expect(demo_payload[:subject]).to eq("[Demo] Payroll reminder")

      # Re-filtering (e.g. PortalNotifications::Transport -> StagingMailTransport) never double-prefixes.
      twice_filtered = DemoOutbound.scoped(demo_company) do
        DemoOutbound.filter_payload(demo_payload)
      end
      expect(twice_filtered[:subject]).to eq("[Demo] Payroll reminder")

      # String keys work the same way.
      string_key_payload = DemoOutbound.scoped(demo_company) do
        DemoOutbound.filter_payload("to" => [ allowlisted ], "subject" => "Invitation")
      end
      expect(string_key_payload[:subject]).to eq("[Demo] Invitation")

      # Live companies never receive the prefix.
      live_payload = DemoOutbound.scoped(live_company) do
        DemoOutbound.filter_payload(to: [ "client@real-client.example" ], subject: "Payroll reminder")
      end
      expect(live_payload[:subject]).to eq("Payroll reminder")
    end

    it "prefixes captured demo deliveries through PortalNotifications::Transport and not live deliveries" do
      DemoOutbound.scoped(demo_company) do
        PortalNotifications::Transport.deliver(
          { from: "noreply@payroll.example", to: [ allowlisted ], subject: "Pay stub ready", text: "Hello" },
          idempotency_key: "demo-marker-1"
        )
      end
      DemoOutbound.scoped(live_company) do
        PortalNotifications::Transport.deliver(
          { from: "noreply@payroll.example", to: [ "employee@real-client.example" ], subject: "Pay stub ready", text: "Hello" },
          idempotency_key: "live-marker-1"
        )
      end

      expect(PortalNotifications::Transport.captured.map { |entry| entry[:subject] }).to eq([
        "[Demo] Pay stub ready",
        "Pay stub ready"
      ])
    end
  end

  describe "PDF footer line" do
    let!(:demo_employee) { create(:employee, company: demo_company, first_name: "Ana", last_name: "Cruz") }
    let!(:live_employee) { create(:employee, company: live_company, first_name: "Ben", last_name: "Santos") }
    let!(:demo_period) do
      create(:pay_period, :committed, company: demo_company,
        start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 14), pay_date: Date.new(2026, 3, 20))
    end
    let!(:live_period) do
      create(:pay_period, :committed, company: live_company,
        start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 14), pay_date: Date.new(2026, 3, 20))
    end
    let!(:demo_item) do
      create(:payroll_item, pay_period: demo_period, employee: demo_employee,
        gross_pay: BigDecimal("1000.00"), net_pay: BigDecimal("820.00"),
        withholding_tax: BigDecimal("103.50"), social_security_tax: BigDecimal("62.00"),
        medicare_tax: BigDecimal("14.50"), check_number: "1001")
    end
    let!(:live_item) do
      create(:payroll_item, pay_period: live_period, employee: live_employee,
        gross_pay: BigDecimal("1000.00"), net_pay: BigDecimal("820.00"),
        withholding_tax: BigDecimal("103.50"), social_security_tax: BigDecimal("62.00"),
        medicare_tax: BigDecimal("14.50"), check_number: "2001")
    end

    it "adds the demo footer to PayStubGenerator only for demos, preserves employee_payroll_facts_sha256, and keeps real-stub footer geometry unchanged" do
      demo_gen = PayStubGenerator.new(demo_item)
      live_gen = PayStubGenerator.new(live_item)

      demo_pdf = demo_gen.generate
      live_pdf = live_gen.generate

      expect(pdf_text(demo_pdf)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(live_pdf)).not_to include(DemoPdfFooter::TEXT)

      # Real-company pay stubs must keep their footer rule at y=26.0 (not shifted up to 34).
      live_raw = PDF::Reader.new(StringIO.new(live_pdf)).pages.first.raw_content
      expect(live_raw).to match(/\b32\.0+\s+26\.0+\s+m\s+580\.0+\s+26\.0+\s+l\b/)
      expect(live_raw).not_to match(/\b32\.0+\s+34\.0+\s+m\s+580\.0+\s+34\.0+\s+l\b/)
      live_footer_ys = text_y_positions(live_pdf, "official earnings statement")
      expect(live_footer_ys).not_to be_empty
      expect(live_footer_ys).to all(be < 26.0)

      # The Demo PDF footer does not alter the semantic pay facts fingerprint.
      before_digest = live_gen.employee_payroll_facts_sha256
      allow(live_item.pay_period.company).to receive(:demo?).and_return(true)
      demo_flagged_gen = PayStubGenerator.new(live_item)
      expect(pdf_text(demo_flagged_gen.generate)).to include(DemoPdfFooter::TEXT)
      expect(demo_flagged_gen.employee_payroll_facts_sha256).to eq(before_digest)
    end

    it "places the demo footer >= 14pt clear of both stub edges across stocks and printer offsets -0.5, 0, +0.5" do
      [ -0.5, 0.0, 0.5 ].each do |offset_y|
        # top_check: check face is y = 528..792; lower stub (stub2) is y = 0..264.
        demo_company.update!(check_stock_type: "top_check", check_offset_y: offset_y)
        top_pdf = CheckGenerator.new(demo_item.reload).generate
        expect(pdf_text(top_pdf)).to include(DemoPdfFooter::TEXT)
        top_ys = demo_footer_y_positions(top_pdf)
        expect(top_ys).not_to be_empty
        expect(top_ys).to all(be_between(14.0, CheckGenerator::SECTION_HEIGHT - 14.0)),
          "top_check offset #{offset_y}: expected >=14pt clearance inside [0, #{CheckGenerator::SECTION_HEIGHT}], got #{top_ys.inspect}"

        # bottom_check: check face + MICR is y = 0..264; lower stub (stub2) is y = 264..528.
        demo_company.update!(check_stock_type: "bottom_check", check_offset_y: offset_y)
        bottom_pdf = CheckGenerator.new(demo_item.reload).generate
        expect(pdf_text(bottom_pdf)).to include(DemoPdfFooter::TEXT)
        bottom_ys = demo_footer_y_positions(bottom_pdf)
        expect(bottom_ys).not_to be_empty
        expect(bottom_ys).to all(be_between(CheckGenerator::SECTION_HEIGHT + 14.0, (CheckGenerator::SECTION_HEIGHT * 2) - 14.0)),
          "bottom_check offset #{offset_y}: expected >=14pt clearance inside [#{CheckGenerator::SECTION_HEIGHT}, #{CheckGenerator::SECTION_HEIGHT * 2}], got #{bottom_ys.inspect}"
      end

      # Real live company checks never print the demo footer.
      live_pdf = CheckGenerator.new(live_item).generate
      expect(pdf_text(live_pdf)).not_to include(DemoPdfFooter::TEXT)
    end

    it "places the demo footer >= 14pt clear of both stub edges on non-employee checks across stocks and offsets and on vouchers only for demos" do
      demo_check = create(:non_employee_check, company: demo_company, payable_to: "Demo Vendor", amount: BigDecimal("250.00"))
      live_check = create(:non_employee_check, company: live_company, payable_to: "Live Vendor", amount: BigDecimal("250.00"))

      [ -0.5, 0.0, 0.5 ].each do |offset_y|
        demo_company.update!(check_stock_type: "top_check", check_offset_y: offset_y)
        top_pdf = NonEmployeeCheckGenerator.new(demo_check.reload).generate
        expect(pdf_text(top_pdf)).to include(DemoPdfFooter::TEXT)
        expect(demo_footer_y_positions(top_pdf)).to all(be_between(14.0, NonEmployeeCheckGenerator::SECTION_HEIGHT - 14.0))

        demo_company.update!(check_stock_type: "bottom_check", check_offset_y: offset_y)
        bottom_pdf = NonEmployeeCheckGenerator.new(demo_check.reload).generate
        expect(pdf_text(bottom_pdf)).to include(DemoPdfFooter::TEXT)
        expect(demo_footer_y_positions(bottom_pdf)).to all(be_between(NonEmployeeCheckGenerator::SECTION_HEIGHT + 14.0, (NonEmployeeCheckGenerator::SECTION_HEIGHT * 2) - 14.0))
      end

      expect(pdf_text(NonEmployeeCheckGenerator.new(live_check).generate)).not_to include(DemoPdfFooter::TEXT)
      voucher_pdf = NonEmployeeCheckVoucherGenerator.new(demo_check).generate
      expect(pdf_text(voucher_pdf)).to include(DemoPdfFooter::TEXT)
      expect(demo_footer_y_positions(voucher_pdf)).to all(be >= 18.0)
      expect(pdf_text(NonEmployeeCheckVoucherGenerator.new(live_check).generate)).not_to include(DemoPdfFooter::TEXT)
    end

    it "keeps SW-2 DRAFT at its original y=18 position and draws the demo footer beneath it" do
      demo_packet = QuarterlyCompliancePacketBuilder.new(demo_company, 2026, 1).generate
      live_packet = QuarterlyCompliancePacketBuilder.new(live_company, 2026, 1).generate

      demo_sw2 = QuarterlyComplianceOfficialForms::Sw2.new(report: demo_packet, demo: true).generate
      live_sw2 = QuarterlyComplianceOfficialForms::Sw2.new(report: live_packet, demo: false).generate

      expect(pdf_text(demo_sw2)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(live_sw2)).not_to include(DemoPdfFooter::TEXT)

      demo_draft_ys = text_y_positions(demo_sw2, "DRAFT")
      live_draft_ys = text_y_positions(live_sw2, "DRAFT")
      expect(demo_draft_ys).not_to be_empty
      expect(demo_draft_ys).to eq(live_draft_ys)

      sw2_demo_ys = demo_footer_y_positions(demo_sw2)
      expect(sw2_demo_ys).not_to be_empty
      expect(sw2_demo_ys).to all(be < demo_draft_ys.min)
    end

    it "marks Form 500, W-3SS, W-2GU copies, 1099-NEC copies, and report PDFs only for demos with y >= 18pt" do
      # Form 500
      demo_f500 = Form500Generator.new(fields: Form500Generator.default_fields(company: demo_company, pay_period: demo_period), demo: true).generate
      live_f500 = Form500Generator.new(fields: Form500Generator.default_fields(company: live_company, pay_period: live_period), demo: false).generate
      expect(pdf_text(demo_f500)).to include(DemoPdfFooter::TEXT)
      expect(demo_footer_y_positions(demo_f500)).to all(be >= 18.0)
      expect(pdf_text(live_f500)).not_to include(DemoPdfFooter::TEXT)

      # W-2GU official copies + W-3SS + W-2GU summary PDF
      demo_w2_report = W2GuAggregator.new(demo_company, 2026).generate
      live_w2_report = W2GuAggregator.new(live_company, 2026).generate
      demo_w2_copies = W2GuOfficialCopies.new(company: demo_company, report: demo_w2_report, kind: "employee", draft: true).generate
      expect(pdf_text(demo_w2_copies)).to include(DemoPdfFooter::TEXT)
      expect(demo_footer_y_positions(demo_w2_copies)).to all(be >= 18.0)
      expect(pdf_text(W2GuOfficialCopies.new(company: live_company, report: live_w2_report, kind: "employee", draft: true).generate)).not_to include(DemoPdfFooter::TEXT)
      demo_w3ss = W3ssPdfGenerator.new(company: demo_company, report: demo_w2_report, draft: true).generate
      expect(pdf_text(demo_w3ss)).to include(DemoPdfFooter::TEXT)
      expect(demo_footer_y_positions(demo_w3ss)).to all(be >= 18.0)
      expect(pdf_text(W3ssPdfGenerator.new(company: live_company, report: live_w2_report, draft: true).generate)).not_to include(DemoPdfFooter::TEXT)
      expect(pdf_text(W2GuPdfGenerator.new(demo_w2_report, demo: true).generate)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(W2GuPdfGenerator.new(live_w2_report, demo: false).generate)).not_to include(DemoPdfFooter::TEXT)

      # 1099-NEC official copies + summary PDF
      create(:information_return_threshold, tax_year: 2026, threshold_amount: 600)
      demo_contractor = create(:employee, :contractor, company: demo_company, first_name: "Cara", last_name: "Diaz",
        ssn_encrypted: "123-45-6789", address_line1: "100 Main St", city: "Hagatna", state: "GU", zip: "96910")
      live_contractor = create(:employee, :contractor, company: live_company, first_name: "Dan", last_name: "Lee",
        ssn_encrypted: "234-56-7890", address_line1: "200 Main St", city: "Hagatna", state: "GU", zip: "96910")
      create(:payroll_item, pay_period: demo_period, employee: demo_contractor, employment_type: "contractor",
        gross_pay: BigDecimal("2500.00"), net_pay: BigDecimal("2500.00"))
      create(:payroll_item, pay_period: live_period, employee: live_contractor, employment_type: "contractor",
        gross_pay: BigDecimal("2500.00"), net_pay: BigDecimal("2500.00"))

      demo_1099_report = Form1099NecAggregator.new(demo_company, 2026).generate
      live_1099_report = Form1099NecAggregator.new(live_company, 2026).generate
      demo_1099_copies = Form1099NecOfficialCopies.new(company: demo_company, report: demo_1099_report, kind: "recipient", draft: true).generate
      expect(pdf_text(demo_1099_copies)).to include(DemoPdfFooter::TEXT)
      expect(demo_footer_y_positions(demo_1099_copies)).to all(be >= 18.0)
      expect(pdf_text(Form1099NecOfficialCopies.new(company: live_company, report: live_1099_report, kind: "recipient", draft: true).generate)).not_to include(DemoPdfFooter::TEXT)
      expect(pdf_text(Form1099NecPdfGenerator.new(demo_1099_report, demo: true).generate)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(Form1099NecPdfGenerator.new(live_1099_report, demo: false).generate)).not_to include(DemoPdfFooter::TEXT)

      # Report & transmittal PDFs (all demo footers render at y >= 18pt)
      sheets = [ { name: "Summary", rows: [ [ "Item", "Total" ], [ "Gross", "1000.00" ] ] } ]
      expect(pdf_text(TabularReportPdfGenerator.new(title: "Report", subtitle: "Sub", filename: "r.pdf", sheets: sheets, demo: true).generate)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(TabularReportPdfGenerator.new(title: "Report", subtitle: "Sub", filename: "r.pdf", sheets: sheets, demo: false).generate)).not_to include(DemoPdfFooter::TEXT)
      expect(pdf_text(InstallmentLoanReportPdfGenerator.new(demo_company).generate)).to include(DemoPdfFooter::TEXT)
      expect(pdf_text(InstallmentLoanReportPdfGenerator.new(live_company).generate)).not_to include(DemoPdfFooter::TEXT)

      [
        [ PayrollSummaryByEmployeePdfGenerator.new(demo_period).generate, PayrollSummaryByEmployeePdfGenerator.new(live_period).generate ],
        [ DeductionsContributionsReportPdfGenerator.new(demo_period).generate, DeductionsContributionsReportPdfGenerator.new(live_period).generate ],
        [ PaycheckHistoryPdfGenerator.new(demo_period).generate, PaycheckHistoryPdfGenerator.new(live_period).generate ],
        [ RetirementPlansReportPdfGenerator.new(demo_period).generate, RetirementPlansReportPdfGenerator.new(live_period).generate ],
        [ CheckSignoffPdfGenerator.new(demo_period).generate, CheckSignoffPdfGenerator.new(live_period).generate ],
        [ TransmittalLogPdfGenerator.new(demo_period).generate, TransmittalLogPdfGenerator.new(live_period).generate ]
      ].each do |demo_pdf, live_pdf|
        expect(pdf_text(demo_pdf)).to include(DemoPdfFooter::TEXT)
        expect(demo_footer_y_positions(demo_pdf)).to all(be >= 18.0)
        expect(pdf_text(live_pdf)).not_to include(DemoPdfFooter::TEXT)
      end
    end
  end

  describe "public tenant branding demo flag" do
    before do
      live_company.update!(subdomain_slug: "live-harbor-cafe")
      demo_company.update!(subdomain_slug: "demo-sunset-grill")
      [ live_company, demo_company ].each do |company|
        company.client_operating_profiles.create!(
          effective_on: PayrollBusinessClock.today,
          version: 1,
          offering: "payroll_service",
          hours_source: "manual",
          options: { subdomain_enabled: true }
        )
      end
      TenantSubdomainRegistry.invalidate!
    end

    it "returns demo: true for demo companies and demo: false for live companies" do
      expect(TenantSubdomainRegistry.branding_for(slug: "demo-sunset-grill")[:demo]).to be(true)
      expect(TenantSubdomainRegistry.branding_for(slug: "live-harbor-cafe")[:demo]).to be(false)
    end
  end
end
