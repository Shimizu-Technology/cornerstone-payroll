# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollFilingResponsibilities", type: :request do
  let!(:company) { create(:company) }
  let!(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayrollFilingResponsibilitiesController)
      .to receive(:current_user).and_return(accountant)
    allow_any_instance_of(Api::V1::Admin::PayrollFilingResponsibilitiesController)
      .to receive(:current_company_id).and_return(company.id)
  end

  it "returns a grouped, server-authored quarterly gate" do
    get "/api/v1/admin/payroll_filing_responsibilities", params: { tax_year: 2026, quarter: 2 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "scope")).to eq("quarterly")
    expect(response.parsed_body.dig("data", "filings").keys).to contain_exactly(
      "form_941", "guam_withholding", "swica"
    )
    expect(response.parsed_body.dig("permissions", "can_record")).to be(true)
  end

  it "lets an accountant apply one attributed decision to all quarterly filing types" do
    expect {
      put "/api/v1/admin/payroll_filing_responsibilities", params: {
        responsibility: {
          tax_year: 2026,
          quarter: 2,
          responsible_party: "cornerstone",
          imported_payroll_inclusion: "included",
          source_cutoff_date: "2026-04-01",
          notes: "Cornerstone will file the complete quarter using both payroll sources."
        }
      }
    }.to change(PayrollFilingResponsibility, :count).by(3)

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("data").map { |row| row.fetch("filing_type") }).to contain_exactly(
      "form_941", "guam_withholding", "swica"
    )

    records = company.payroll_filing_responsibilities.for_year(2026).for_quarter(2)
    expect(records.pluck(:reviewed_by_id).uniq).to eq([ accountant.id ])
    expect(records.pluck(:reviewed_by_name).uniq).to eq([ accountant.name ])
    expect(records.pluck(:reviewed_by_email).uniq).to eq([ accountant.email ])
    expect(records.pluck(:source_cutoff_date).uniq).to eq([ Date.new(2026, 4, 1) ])

    audit = AuditLog.where(action: "payroll_filing_responsibilities#recorded").order(:id).last
    expect(audit).to be_present
    expect(audit.user_id).to eq(accountant.id)
    expect(audit.company_id).to eq(company.id)
    expect(audit.metadata.fetch("filing_types")).to contain_exactly("form_941", "guam_withholding", "swica")
  end

  it "records annual W-2GU independently from quarterly responsibilities" do
    put "/api/v1/admin/payroll_filing_responsibilities", params: {
      responsibility: {
        tax_year: 2026,
        filing_type: "w2_gu",
        responsible_party: "external_provider",
        imported_payroll_inclusion: "excluded",
        notes: "The predecessor provider owns the annual W-2GU filing."
      }
    }

    expect(response).to have_http_status(:ok), response.body
    record = PayrollFilingResponsibility.find_by!(company: company, tax_year: 2026, filing_type: "w2_gu")
    expect(record.quarter).to be_nil
    expect(response.parsed_body.dig("filing_gate", "filings", "w2_gu", "status")).to eq("external_provider_responsible")
  end

  it "rejects a quarterly filing type without a quarter" do
    put "/api/v1/admin/payroll_filing_responsibilities", params: {
      responsibility: {
        tax_year: 2026,
        filing_type: "form_941",
        responsible_party: "cornerstone",
        imported_payroll_inclusion: "included"
      }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/quarter must be 1, 2, 3, or 4/)
  end

  it "does not accept a client id from the decision payload" do
    other_company = create(:company, organization: company.organization)

    put "/api/v1/admin/payroll_filing_responsibilities", params: {
      responsibility: {
        company_id: other_company.id,
        tax_year: 2026,
        filing_type: "w2_gu",
        responsible_party: "cornerstone",
        imported_payroll_inclusion: "included"
      }
    }

    expect(response).to have_http_status(:ok), response.body
    expect(PayrollFilingResponsibility.find_by!(tax_year: 2026, filing_type: "w2_gu").company_id).to eq(company.id)
  end

  it "denies client-role users" do
    client_user = create(:user, company: company, organization: company.organization, role: "client")
    allow_any_instance_of(Api::V1::Admin::PayrollFilingResponsibilitiesController)
      .to receive(:current_user).and_return(client_user)

    get "/api/v1/admin/payroll_filing_responsibilities", params: { tax_year: 2026 }

    expect(response).to have_http_status(:forbidden)
  end
end
