# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tax Configs Admin API", type: :request do
  describe "GET /api/v1/admin/tax_configs" do
    it "returns all tax configs" do
      create(:annual_tax_config, tax_year: 2500)
      create(:annual_tax_config, tax_year: 2501)

      get "/api/v1/admin/tax_configs"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["tax_configs"].length).to be >= 2
    end

    it "orders by tax_year descending" do
      create(:annual_tax_config, tax_year: 2600)
      create(:annual_tax_config, tax_year: 2602)
      create(:annual_tax_config, tax_year: 2601)

      get "/api/v1/admin/tax_configs"

      json = JSON.parse(response.body)
      years = json["tax_configs"].map { |c| c["tax_year"] }
      # Check that these specific years are in descending order within the results
      test_years = years.select { |y| y >= 2600 }
      expect(test_years).to eq([2602, 2601, 2600])
    end
  end

  describe "GET /api/v1/admin/tax_configs/:id" do
    it "returns tax config with brackets" do
      config = create(:annual_tax_config, tax_year: 2700)
      fsc = create(:filing_status_config, annual_tax_config: config, filing_status: "single")
      create(:tax_bracket, filing_status_config: fsc, bracket_order: 1)

      get "/api/v1/admin/tax_configs/#{config.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["tax_config"]["tax_year"]).to eq(2700)
      expect(json["tax_config"]["filing_statuses"].first["brackets"]).to be_present
    end
  end

  describe "POST /api/v1/admin/tax_configs" do
    it "creates a new tax config" do
      post "/api/v1/admin/tax_configs",
           params: {
             tax_year: 2800,
             ss_wage_base: 175_000,
             ss_rate: 0.062,
             medicare_rate: 0.0145,
             additional_medicare_rate: 0.009,
             additional_medicare_threshold: 200_000
           }

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["tax_config"]["tax_year"]).to eq(2800)
    end

    it "creates config by copying from previous year" do
      source = create(:annual_tax_config, tax_year: 2850, ss_wage_base: 184_500)
      fsc = create(:filing_status_config, annual_tax_config: source, filing_status: "single")
      create(:tax_bracket, filing_status_config: fsc, bracket_order: 1, rate: 0.10)

      post "/api/v1/admin/tax_configs",
           params: { tax_year: 2851, copy_from_year: 2850 }

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["tax_config"]["ss_wage_base"]).to eq(184_500)
      expect(json["tax_config"]["filing_statuses"].first["brackets"].first["rate"]).to eq(0.1)
    end

    it "logs creation in audit log" do
      expect {
        post "/api/v1/admin/tax_configs",
             params: {
               tax_year: 2900,
               ss_wage_base: 180_000,
               ss_rate: 0.062,
               medicare_rate: 0.0145,
               additional_medicare_rate: 0.009,
               additional_medicare_threshold: 200_000
             }
      }.to change(TaxConfigAuditLog, :count).by(1)
    end
  end

  describe "PATCH /api/v1/admin/tax_configs/:id" do
    it "updates the tax config" do
      config = create(:annual_tax_config, tax_year: 2950, ss_wage_base: 160_200)

      patch "/api/v1/admin/tax_configs/#{config.id}",
            params: { ss_wage_base: 168_600 }

      expect(response).to have_http_status(:ok)
      expect(config.reload.ss_wage_base.to_i).to eq(168_600)
    end

    it "logs changes in audit log" do
      config = create(:annual_tax_config, tax_year: 2951, ss_wage_base: 160_200)

      expect {
        patch "/api/v1/admin/tax_configs/#{config.id}",
              params: { ss_wage_base: 168_600 }
      }.to change(TaxConfigAuditLog, :count).by(1)

      log = TaxConfigAuditLog.last
      expect(log.field_name).to eq("ss_wage_base")
      expect(log.old_value).to include("160200")
      expect(log.new_value).to include("168600")
    end
  end

  describe "DELETE /api/v1/admin/tax_configs/:id" do
    it "deletes inactive tax config" do
      config = create(:annual_tax_config, is_active: false)

      delete "/api/v1/admin/tax_configs/#{config.id}"

      expect(response).to have_http_status(:ok)
      expect(AnnualTaxConfig.find_by(id: config.id)).to be_nil
    end

    it "prevents deletion of active tax config" do
      config = create(:annual_tax_config, is_active: true)

      delete "/api/v1/admin/tax_configs/#{config.id}"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AnnualTaxConfig.find_by(id: config.id)).to be_present
    end
  end

  describe "POST /api/v1/admin/tax_configs/:id/activate" do
    it "activates the config" do
      config = create(:annual_tax_config, is_active: false)

      post "/api/v1/admin/tax_configs/#{config.id}/activate"

      expect(response).to have_http_status(:ok)
      expect(config.reload.is_active).to be true
    end

    it "deactivates other configs" do
      old_active = create(:annual_tax_config, tax_year: 3000, is_active: true)
      new_config = create(:annual_tax_config, tax_year: 3001, is_active: false)

      post "/api/v1/admin/tax_configs/#{new_config.id}/activate"

      expect(old_active.reload.is_active).to be false
    end

    it "logs activation and deactivation" do
      old_active = create(:annual_tax_config, tax_year: 3100, is_active: true)
      new_config = create(:annual_tax_config, tax_year: 3101, is_active: false)

      expect {
        post "/api/v1/admin/tax_configs/#{new_config.id}/activate"
      }.to change(TaxConfigAuditLog, :count).by(2)
    end
  end

  describe "GET /api/v1/admin/tax_configs/:id/audit_logs" do
    it "returns audit logs for the config" do
      config = create(:annual_tax_config)
      TaxConfigAuditLog.log_created(config)
      TaxConfigAuditLog.log_updated(config, field_name: "ss_wage_base", old_value: 160_200, new_value: 168_600)

      get "/api/v1/admin/tax_configs/#{config.id}/audit_logs"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["audit_logs"].length).to eq(2)
    end
  end

  describe "PATCH /api/v1/admin/tax_configs/:id/filing_status/:filing_status" do
    it "updates filing status standard deduction" do
      config = create(:annual_tax_config)
      fsc = create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 14_600)

      patch "/api/v1/admin/tax_configs/#{config.id}/filing_status/single",
            params: { standard_deduction: 15_000 }

      expect(response).to have_http_status(:ok)
      expect(fsc.reload.standard_deduction.to_i).to eq(15_000)
    end
  end

  describe "PATCH /api/v1/admin/tax_configs/:id/brackets/:filing_status" do
    it "updates tax brackets" do
      config = create(:annual_tax_config)
      fsc = create(:filing_status_config, annual_tax_config: config, filing_status: "single")
      bracket = create(:tax_bracket, filing_status_config: fsc, bracket_order: 1, rate: 0.10, min_income: 0, max_income: 11_600)

      patch "/api/v1/admin/tax_configs/#{config.id}/brackets/single",
            params: {
              brackets: [
                { bracket_order: 1, rate: 0.10, min_income: 0, max_income: 12_000 }
              ]
            }

      expect(response).to have_http_status(:ok)
      expect(bracket.reload.max_income.to_i).to eq(12_000)
    end
  end
end
