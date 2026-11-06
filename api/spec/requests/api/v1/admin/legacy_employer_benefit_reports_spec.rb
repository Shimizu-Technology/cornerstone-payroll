# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Legacy employer benefit report compatibility", type: :request do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) do
    create(:payroll_item, company: company, employee: employee, pay_period: period,
      gross_pay: 1000, net_pay: 873.50, retirement_payment: 50,
      social_security_tax: 62, medicare_tax: 14.50, total_deductions: 126.50)
  end
  let(:definition) do
    create(:payroll_field_definition, company: company, name: "Saved employer health",
      kind: "employer_contribution", tax_treatment: "employer_contribution", category: "benefit")
  end
  let!(:field) do
    item.payroll_item_field_entries.create!(payroll_field_definition: definition,
      label: definition.name, kind: definition.kind, tax_treatment: definition.tax_treatment,
      category: definition.category, amount: 25, active: true, metadata: {})
  end
  let!(:deduction) do
    type = company.deduction_types.create!(name: definition.name,
      category: "employer_contribution", sub_category: "benefit")
    item.payroll_item_deductions.create!(deduction_type: type, label: definition.name,
      category: "employer_contribution", amount: 25)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(actor)
  end

  def report_get(action, **params)
    get "/api/v1/admin/reports/#{action}", params: { pay_period_id: period.id, year: period.pay_date.year, **params }
  end

  def pdf_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
  end

  context "when legacy benefits are in a prior committed period" do
    let(:later_period) { create(:pay_period, :committed, company: company, pay_date: period.pay_date + 14) }
    let(:later_item) { create(:payroll_item, :with_check, employee: employee, pay_period: later_period) }

    before do
      [ Api::V1::Admin::PayStubsController, Api::V1::Admin::ChecksController ].each do |controller|
        allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
        allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      end
      allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:r2_configured?).and_return(false)
    end

    it "downloads the current earnings statement and check without exposing the historical review note" do
      get "/api/v1/admin/pay_stubs/#{later_item.id}/download"
      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("Saved employer health", "$25.00")
      expect(pdf_text(response.body)).not_to include("Legacy employer benefit history", "accountant review needed")
      get "/api/v1/admin/payroll_items/#{later_item.id}/check"
      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("Saved employer health", "25.00")
      expect(pdf_text(response.body)).not_to include("Legacy employer benefit history", "accountant review needed")
    end

    it "bypasses stored statements with prior legacy warnings without changing safe cached downloads" do
      later_item.update_columns(payment_delivery_method: nil)
      storage = instance_double(R2StorageService)
      allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:r2_configured?).and_return(true)
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:exists?).and_return(true)
      expect(storage).not_to receive(:download)

      get "/api/v1/admin/pay_stubs/#{later_item.id}/download"
      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("Saved employer health", "$25.00")
      expect(pdf_text(response.body)).not_to include("Legacy employer benefit history", "accountant review needed")
    end

    it "keeps employee batch statements free of accountant review notes" do
      later_item
      post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: later_period.id }
      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("Saved employer health", "$25.00")
      expect(pdf_text(response.body)).not_to include("Legacy employer benefit history", "accountant review needed")
    end

    it "returns 422 for genuinely ambiguous prior history in statement and check downloads" do
      type = company.deduction_types.create!(name: "Another employer health", category: "employer_contribution", sub_category: "benefit")
      item.payroll_item_deductions.create!(deduction_type: type, label: definition.name, category: "employer_contribution", amount: 25)
      [ "/api/v1/admin/pay_stubs/#{later_item.id}/download", "/api/v1/admin/payroll_items/#{later_item.id}/check" ].each do |path|
        get path
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to include("ambiguous", "reviewed component reconciliation")
      end
      post "/api/v1/admin/pay_stubs/#{later_item.id}/generate"
      expect(response).to have_http_status(:unprocessable_entity)
      post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: later_period.id }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  [ false, true ].each do |instrument_voided|
    context "with instrument voided=#{instrument_voided}, without a wage reversal" do
      before { item.update_columns(voided: instrument_voided) }

      it "reads saved components once, preserves employee retirement, and flags the unresolved classification" do
        saved = [ item.reload.attributes, field.reload.attributes, deduction.reload.attributes ]
        data = QuickbooksPayrollReportData.new(period)
        entries = data.deduction_contribution_entries_for_item(item)
        expect(entries.sum(&:company_amount)).to eq(25)
        expect(entries.sum(&:employee_amount)).to eq(50)
        expect(data.review_warnings).to include(include(code: "legacy_employer_benefit_unclassified", payroll_item_id: item.id))
        expect(PayrollRetirementTotals.for_item(item, for_reporting: true)).to eq(retirement: 50.to_d, roth_retirement: 0.to_d)
        expect(PayrollRetirementTotals.additions_for_item(item, for_reporting: true)).to eq(employer: 0.to_d, non_roth_after_tax: 0.to_d)
        expect([ item.reload.attributes, field.reload.attributes, deduction.reload.attributes ]).to eq(saved)
        expect(period.payroll_liability_postings).to be_empty
      end

      it "generates W-2/W-3 inputs with the saved main-compatible amounts and a visible review issue" do
        report_get("w2_gu")
        expect(response).to have_http_status(:ok)
        report = response.parsed_body.fetch("report")
        expect(report.fetch("totals")).to include(
          "box1_wages_tips_other_comp" => 950, "box3_social_security_wages" => 1000,
          "box5_medicare_wages_tips" => 1000, "box12_code_d_total" => 50
        )
        expect(report.fetch("review_warnings")).to include(include("payroll_item_id" => item.id))
        expect(report.fetch("compliance_issues")).to include(PayrollReportComponentReview::MESSAGE)
        report_get("w2_gu_pdf")
        expect(response).to have_http_status(:ok)
        expect(pdf_text(response.body)).to include(PayrollReportComponentReview::MESSAGE)
      end

      it "generates the employee summary PDF and JSON data with a single $25 employer contribution" do
        report_get("payroll_summary_by_employee_pdf")
        expect(response).to have_http_status(:ok)
        expect(pdf_text(response.body)).to include(PayrollReportComponentReview::MESSAGE, "Saved employer health", "$25.00")
        controller = Api::V1::Admin::ReportsController.new
        report = controller.send(:build_pay_period_payroll_items_report, period)
        expect(report[:summary]).to include(total_gross: 1000, total_net: 873.50, total_payroll_field_employer_contributions: 25)
        expect(report[:review_warnings]).to include(include(payroll_item_id: item.id))
      end

      it "generates date summaries and register JSON/PDF with saved money and a review flag" do
        report_get("ytd_summary")
        expect(response).to have_http_status(:ok)
        report = response.parsed_body.fetch("report")
        expect(report.fetch("company_totals")).to include("gross_pay" => 1000, "net_pay" => 873.50, "retirement" => 50)
        expect(report.fetch("review_warnings")).to include(include("payroll_item_id" => item.id))
        report_get("ytd_summary_pdf")
        expect(response).to have_http_status(:ok)
        expect(pdf_text(response.body)).to include(PayrollReportComponentReview::MESSAGE)
        report_get("payroll_register")
        expect(response).to have_http_status(:ok)
        register = response.parsed_body.fetch("report")
        expect(register.fetch("summary").slice("total_gross", "total_net").transform_values(&:to_d)).to eq("total_gross" => 1000.to_d, "total_net" => 873.50.to_d)
        expect(register.fetch("review_warnings")).to include(include("payroll_item_id" => item.id))
        report_get("payroll_register_pdf")
        expect(response).to have_http_status(:ok)
        expect(pdf_text(response.body)).to include(PayrollReportComponentReview::MESSAGE)
      end

      it "keeps the warning on accountant PDFs, workbook Report Info sheets, and item disclosure" do
        %w[deductions_contributions_pdf paycheck_history_pdf retirement_plans_pdf full_print_package_pdf].each do |action|
          report_get(action)
          expect(response).to have_http_status(:ok), "#{action}: #{response.body.first(200)}"
          expect(pdf_text(response.body)).to include(PayrollReportComponentReview::MESSAGE)
        end
        %w[payroll_summary_by_employee_xlsx ytd_summary_xlsx payroll_register_xlsx
          deductions_contributions_xlsx paycheck_history_xlsx retirement_plans_xlsx].each do |action|
          report_get(action)
          expect(response).to have_http_status(:ok), action
          Zip::File.open_buffer(response.body) do |zip|
            workbook = Nokogiri::XML(zip.read("xl/workbook.xml"))
            sheets = workbook.remove_namespaces!.xpath("//sheet")
            index = sheets.index { |sheet| sheet["name"] == "Report Info" }
            expect(index).not_to be_nil, action
            info = Nokogiri::XML(zip.read("xl/worksheets/sheet#{index + 1}.xml")).remove_namespaces!
            expect(info.xpath("//t").map(&:text).join(" ")).to include(PayrollReportComponentReview::MESSAGE), action
          end
        end
        allow_any_instance_of(Api::V1::Admin::PayrollItemsController).to receive(:current_company_id).and_return(company.id)
        allow_any_instance_of(Api::V1::Admin::PayrollItemsController).to receive(:current_user).and_return(actor)
        get "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}"
        expect(response).to have_http_status(:ok)
        warnings = response.parsed_body.dig("payroll_item", "component_disclosure", "review_warnings")
        expect(warnings).to include(include("message" => PayrollReportComponentReview::MESSAGE, "payroll_item_id" => item.id))
      end

      it "keeps calculation, correction components and liability writes strict" do
        expect { PayrollComponentMirrors.resolution(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollRetirementTotals.for_item(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollRetirementTotals.additions_for_item(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { QuickbooksPayrollReportData.new(period, for_reporting: false).deduction_contribution_entries_for_item(item) }
          .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollComponentMirrors.deduction_for(item, field) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { CorrectiveRetirementContext.allocate.send(:amounts, item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollEmployerContributions.sources(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollCalculator.new(employee, item).send(:update_ytd_on_item) }
          .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
        expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
          .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /ambiguous/)
        expect(period.payroll_liability_postings).to be_empty
      end
    end
  end

  %w[insurance retirement].each do |category|
    it "retains a legacy #{category} employer mirror once without relaxing writes" do
      group = category == "retirement" ? "401k_pre_tax" : nil
      field.update!(category: category, reporting_group: group)
      deduction.update!(reporting_group: group)
      deduction.deduction_type.update!(sub_category: category, reporting_group: group)
      item.reload
      report = QuickbooksPayrollReportData.new(period)
      expect(report.employer_contribution_total(item)).to eq(25)
      expect(report.review_warnings).to include(include(payroll_item_id: item.id))
      expect(PayrollRetirementTotals.for_item(item, for_reporting: true)).to eq(retirement: 50.to_d, roth_retirement: 0.to_d)
      expect(PayrollRetirementTotals.additions_for_item(item, for_reporting: true)[:employer]).to eq(category == "retirement" ? 25 : 0)
      expect { PayrollRetirementTotals.additions_for_item(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
    end
  end

  [ {}, { "lifecycle_legacy_capture" => true } ].each do |metadata|
    it "requires strict proof for qualifying posted history (posting metadata #{metadata.inspect})" do
      period.payroll_liability_postings.create!(company: company, posting_type: "commit",
        liability_date: period.pay_date, posted_at: Time.current,
        idempotency_key: "legacy-review-#{period.id}", metadata: metadata)
      if metadata.empty?
        expect { QuickbooksPayrollReportData.new(period).deduction_contribution_entries_for_item(item) }
          .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
      else
        expect(QuickbooksPayrollReportData.new(period).employer_contribution_total(item)).to eq(25)
        expect(PayrollReportComponentReview.for_item(item)).to include(include(payroll_item_id: item.id))
      end
      expect { PayrollComponentMirrors.resolution(item) }.to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
    end
  end

  it "counts local legacy candidates by company/year without changing them and rejects an outer write transaction" do
    snapshot = [ item.reload.attributes, field.reload.attributes, deduction.reload.attributes ]
    inventory = PayrollLegacyEmployerBenefitInventory.send(:inventory)
    expect(inventory[:company_years]).to include(include(company_id: company.id, year: period.pay_date.year,
      payroll_items: 1, employees: 1, employer_field_rows: 1, employer_deduction_rows: 1,
      report_compatible_review_items: 1, ambiguous_items: 0))
    expect { PayrollLegacyEmployerBenefitInventory.call }.to raise_error(ArgumentError, /read-only transaction/)
    expect([ item.reload.attributes, field.reload.attributes, deduction.reload.attributes ]).to eq(snapshot)
  end

  it "keeps a frozen independent employer deduction separate from an equal field" do
    item.update_columns(calculation_context_snapshot: { "employee_deductions" => [ { "deduction_type" => { "id" => deduction.deduction_type_id } } ] })
    data = QuickbooksPayrollReportData.new(period)
    expect(data.employer_contribution_total(item.reload)).to eq(50)
    expect(data.review_warnings).to be_empty
  end

  it "does not permit report fallback for a modern or explicitly identified conflicting mirror" do
    item.update_columns(calculation_context_snapshot: { "built_in_employer_match_mirrors" => {} })
    expect(PayrollLegacyEmployerBenefitInventory.send(:inventory)[:company_years]).not_to include(include(company_id: company.id))
    expect { QuickbooksPayrollReportData.new(period).deduction_contribution_entries_for_item(item.reload) }
      .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
    item.update_columns(calculation_context_snapshot: {})
    field.update!(metadata: { "deduction_mirror" => { "version" => 99 } })
    expect { QuickbooksPayrollReportData.new(period).deduction_contribution_entries_for_item(item.reload) }
      .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError)
  end

  it "returns a clear 422 for remaining genuinely ambiguous report actions" do
    other_type = company.deduction_types.create!(name: "Independent unclassified health", category: "employer_contribution", sub_category: "benefit")
    item.payroll_item_deductions.create!(deduction_type: other_type, label: definition.name, category: "employer_contribution", amount: 25)
    %w[w2_gu w2_gu_pdf payroll_summary_by_employee_pdf payroll_summary_by_employee_xlsx
      deductions_contributions_pdf deductions_contributions_xlsx retirement_plans_pdf retirement_plans_xlsx
      paycheck_history_pdf paycheck_history_xlsx payroll_register payroll_register_pdf payroll_register_csv
      payroll_register_xlsx ytd_summary ytd_summary_pdf ytd_summary_csv ytd_summary_xlsx].each do |action|
      report_get(action)
      expect(response).to have_http_status(:unprocessable_entity), "#{action}: #{response.status}"
      expect(response.parsed_body.fetch("error")).to include("ambiguous", "reviewed component reconciliation")
    end
  end
end
