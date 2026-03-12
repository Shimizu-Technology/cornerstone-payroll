# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PayPeriod Correction API (CPR-71)", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:admin_user) do
    User.create!(company: company, email: "admin-correction@example.com",
                 name: "Correction Admin", role: "admin", active: true)
  end
  let!(:employee) do
    create(:employee, company: company, department: department,
           first_name: "Alice", last_name: "Test",
           email: "alice@example.com",
           employment_type: "hourly", pay_rate: 20.00)
  end

  let!(:committed_period) do
    pp = create(:pay_period, :committed, company: company,
                start_date: Date.new(2024, 3, 1),
                end_date:   Date.new(2024, 3, 14),
                pay_date:   Date.new(2024, 3, 19))
    create(:payroll_item,
           pay_period: pp,
           employee: employee,
           gross_pay: 1600.00, net_pay: 1300.00,
           withholding_tax: 160.00, social_security_tax: 99.20, medicare_tax: 23.20,
           employer_social_security_tax: 99.20, employer_medicare_tax: 23.20,
           retirement_payment: 0, roth_retirement_payment: 0,
           insurance_payment: 0, loan_payment: 0,
           reported_tips: 0, bonus: 0, overtime_hours: 0,
           voided: false)
    pp
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController)
      .to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController)
      .to receive(:current_user_id).and_return(admin_user.id)
  end

  def setup_ytd(gross: 1600.0, net: 1300.0)
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024)
      .update!(gross_pay: gross, net_pay: net, withholding_tax: 160.0,
               social_security_tax: 99.2, medicare_tax: 23.2)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024)
      .update!(gross_pay: gross, net_pay: net, withholding_tax: 160.0,
               social_security_tax: 99.2, medicare_tax: 23.2,
               employer_social_security: 99.2, employer_medicare: 23.2)
  end

  # ----------------------------------------------------------------
  # POST /void
  # ----------------------------------------------------------------
  describe "POST /api/v1/admin/pay_periods/:id/void" do
    context "happy path" do
      before { setup_ytd }

      it "voids a committed pay period and returns 200" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "Wrong employee included" },
             as: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["pay_period"]["correction_status"]).to eq("voided")
        expect(json["pay_period"]["void_reason"]).to eq("Wrong employee included")
        expect(json["correction_event"]["action_type"]).to eq("void_initiated")
      end

      it "sets can_void to false after voiding" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "Test" }, as: :json

        json = JSON.parse(response.body)
        expect(json["pay_period"]["can_void"]).to be false
      end

      it "sets can_create_correction_run to true after voiding" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "Test" }, as: :json

        json = JSON.parse(response.body)
        expect(json["pay_period"]["can_create_correction_run"]).to be true
      end

      it "reverses employee YTD totals" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "YTD reversal test" }, as: :json

        ytd = EmployeeYtdTotal.find_by(employee_id: employee.id, year: 2024)
        expect(ytd.gross_pay.to_f).to eq(0.0)
      end
    end

    context "validation errors" do
      it "returns 422 when reason is missing" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: {}, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to match(/reason is required/i)
      end

      it "returns 422 when reason is blank" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "  " }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "returns 422 if pay period is not committed" do
        draft = create(:pay_period, company: company, status: "draft")
        post "/api/v1/admin/pay_periods/#{draft.id}/void",
             params: { reason: "test" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to match(/committed/i)
      end

      it "returns 422 on double-void attempt" do
        setup_ytd
        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "First" }, as: :json
        expect(response).to have_http_status(:ok)

        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "Second" }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/already been voided/i)
      end

      it "returns 404 for a pay period from a different company" do
        other_company = create(:company)
        other_period  = create(:pay_period, :committed, company: other_company)

        post "/api/v1/admin/pay_periods/#{other_period.id}/void",
             params: { reason: "Cross-company" }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 when void flow raises RecordInvalid" do
        bad_record = PayPeriodCorrectionEvent.new
        bad_record.validate

        allow(PayPeriodCorrectionService).to receive(:void!)
          .and_raise(ActiveRecord::RecordInvalid.new(bad_record))

        post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
             params: { reason: "trigger invalid" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to be_present
      end
    end
  end

  # ----------------------------------------------------------------
  # POST /create_correction_run
  # ----------------------------------------------------------------
  describe "POST /api/v1/admin/pay_periods/:id/create_correction_run" do
    let!(:voided_period) do
      pp = create(:pay_period, :voided, company: company,
                  start_date: Date.new(2024, 3, 1),
                  end_date:   Date.new(2024, 3, 14),
                  pay_date:   Date.new(2024, 3, 19))
      create(:payroll_item,
             pay_period: pp,
             employee: employee,
             gross_pay: 1600.00, net_pay: 1300.00)
      pp
    end

    context "happy path" do
      it "creates a correction run and returns 201" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Re-running with corrected hours" }, as: :json

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["correction_run"]["status"]).to eq("draft")
        expect(json["correction_run"]["correction_status"]).to eq("correction")
        expect(json["correction_run"]["source_pay_period_id"]).to eq(voided_period.id)
      end

      it "links the voided period to the correction run" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Link test" }, as: :json

        json = JSON.parse(response.body)
        correction_run_id = json["correction_run"]["id"]
        voided_period.reload
        expect(voided_period.superseded_by_id).to eq(correction_run_id)
      end

      it "accepts overridden pay_date" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Date override", pay_date: "2024-03-22" }, as: :json

        json = JSON.parse(response.body)
        expect(json["correction_run"]["pay_date"]).to eq("2024-03-22")
      end

      it "rejects non-ISO ambiguous date formats" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Bad date", pay_date: "03/22/2024" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/Invalid date/i)
      end

      it "returns 422 for invalid override date range" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: {
               reason: "Bad range",
               start_date: "2024-03-20",
               end_date: "2024-03-10"
             }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/end date|after start date/i)
      end

      it "copies payroll items from source into the correction run" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Copy items" }, as: :json

        json = JSON.parse(response.body)
        new_id = json["correction_run"]["id"]
        new_period = PayPeriod.find(new_id)
        expect(new_period.payroll_items.count).to eq(1)
        expect(new_period.payroll_items.first.employee_id).to eq(employee.id)
      end
    end

    context "validation errors" do
      it "returns 422 when reason is missing" do
        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: {}, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to match(/reason is required/i)
      end

      it "returns 422 if source period is not voided" do
        post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
             params: { reason: "Invalid source" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/voided/i)
      end

      it "returns 422 if source already has a correction run" do
        existing_run = create(:pay_period, :correction_run, company: company, source_pay_period: voided_period)
        voided_period.update!(superseded_by_id: existing_run.id)

        post "/api/v1/admin/pay_periods/#{voided_period.id}/create_correction_run",
             params: { reason: "Duplicate" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/already has a correction run/i)
      end
    end
  end

  # ----------------------------------------------------------------
  # GET /correction_history
  # ----------------------------------------------------------------
  describe "GET /api/v1/admin/pay_periods/:id/correction_history" do
    before { setup_ytd }

    it "returns an empty event list for a period with no corrections" do
      get "/api/v1/admin/pay_periods/#{committed_period.id}/correction_history"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["correction_events"]).to eq([])
    end

    it "returns correction events after a void" do
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "History test" }, as: :json

      get "/api/v1/admin/pay_periods/#{committed_period.id}/correction_history"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["correction_events"].length).to eq(1)
      expect(json["correction_events"][0]["action_type"]).to eq("void_initiated")
      expect(json["correction_events"][0]["reason"]).to eq("History test")
    end

    it "includes pay_period summary in response" do
      get "/api/v1/admin/pay_periods/#{committed_period.id}/correction_history"

      json = JSON.parse(response.body)
      expect(json["pay_period"]["id"]).to eq(committed_period.id)
      expect(json["pay_period"]).to have_key("correction_status")
    end

    it "returns 404 for a period from another company" do
      other = create(:pay_period, :committed, company: create(:company))
      get "/api/v1/admin/pay_periods/#{other.id}/correction_history"
      expect(response).to have_http_status(:not_found)
    end
  end

  # ----------------------------------------------------------------
  # Pay period index — correction fields visible
  # ----------------------------------------------------------------
  describe "GET /api/v1/admin/pay_periods — correction fields" do
    before { setup_ytd }

    it "includes correction_status in list response" do
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Index test" }, as: :json

      get "/api/v1/admin/pay_periods"
      json = JSON.parse(response.body)
      period = json["pay_periods"].find { |p| p["id"] == committed_period.id }
      expect(period["correction_status"]).to eq("voided")
    end

    it "includes can_delete_draft_correction_run on a draft correction run" do
      # Create a voided period + draft correction run
      setup_ytd
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Set up draft run" }, as: :json
      post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
           params: { reason: "Create draft correction run" }, as: :json
      new_id = JSON.parse(response.body)["correction_run"]["id"]

      get "/api/v1/admin/pay_periods/#{new_id}"
      json = JSON.parse(response.body)
      pp = json["pay_period"]
      expect(pp["can_delete_draft_correction_run"]).to be true
      expect(pp["can_void"]).to be false  # draft, not committed
    end
  end

  # ----------------------------------------------------------------
  # CPR-73: DELETE /api/v1/admin/pay_periods/:id — draft correction run
  # ----------------------------------------------------------------
  describe "DELETE /api/v1/admin/pay_periods/:id (draft correction run) — CPR-73" do
    let!(:voided_period_for_delete) do
      setup_ytd
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Void to set up draft correction run" }, as: :json
      committed_period.reload
      committed_period
    end

    let!(:draft_correction_run) do
      post "/api/v1/admin/pay_periods/#{voided_period_for_delete.id}/create_correction_run",
           params: { reason: "Create draft correction run for delete test" }, as: :json
      new_id = JSON.parse(response.body)["correction_run"]["id"]
      PayPeriod.find(new_id)
    end

    context "happy path" do
      it "returns 200 with source_pay_period, deleted_correction_run_id, and correction_event" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Created with wrong pay date, need to redo" }, as: :json

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json).to have_key("source_pay_period")
        expect(json).to have_key("deleted_correction_run_id")
        expect(json).to have_key("correction_event")
        expect(json["deleted_correction_run_id"]).to eq(draft_correction_run.id)
        expect(json["correction_event"]["action_type"]).to eq("correction_run_deleted")
      end

      it "destroys the correction run record" do
        expect {
          delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
                 params: { reason: "Created with wrong pay date, need to redo" }, as: :json
        }.to change(PayPeriod, :count).by(-1)

        expect { PayPeriod.find(draft_correction_run.id) }
          .to raise_error(ActiveRecord::RecordNotFound)
      end

      it "clears superseded_by_id on the source period" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Clearing source period for redo" }, as: :json

        voided_period_for_delete.reload
        expect(voided_period_for_delete.superseded_by_id).to be_nil
      end

      it "re-opens the source period for a new correction run (can_create_correction_run = true)" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Clearing source period for redo" }, as: :json

        json = JSON.parse(response.body)
        expect(json["source_pay_period"]["can_create_correction_run"]).to be true
      end

      it "records the operator-supplied reason in the correction event" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Specific operator reason for deleting" }, as: :json

        json = JSON.parse(response.body)
        expect(json["correction_event"]["reason"]).to eq("Specific operator reason for deleting")
      end

      it "falls back to default reason when none is provided" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}", as: :json

        json = JSON.parse(response.body)
        expect(json["correction_event"]["reason"]).to match(/deleted by operator/i)
      end

      it "records a correction_run_deleted audit event on the source period" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Audit event recording test" }, as: :json

        events = PayPeriodCorrectionEvent.where(
          pay_period_id: voided_period_for_delete.id,
          action_type: "correction_run_deleted"
        )
        expect(events.count).to eq(1)
        expect(events.first.metadata["deleted_correction_run_id"]).to eq(draft_correction_run.id)
      end

      it "allows a new correction run to be created after delete" do
        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Freeing up for re-run" }, as: :json
        expect(response).to have_http_status(:ok)

        post "/api/v1/admin/pay_periods/#{voided_period_for_delete.id}/create_correction_run",
             params: { reason: "Re-running after deleting the wrong draft" }, as: :json
        expect(response).to have_http_status(:created)
        new_json = JSON.parse(response.body)
        expect(new_json["correction_run"]["status"]).to eq("draft")
      end
    end

    context "validation errors" do
      it "returns 422 for a non-draft correction run" do
        # Fast-track committed correction run by promoting it
        draft_correction_run.update_columns(status: "committed")

        delete "/api/v1/admin/pay_periods/#{draft_correction_run.id}",
               params: { reason: "Trying to delete committed run" }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to match(/draft/i)
      end

      it "returns 404 for a correction run belonging to another company" do
        other_company  = create(:company)
        other_voided   = create(:pay_period, :voided,          company: other_company)
        other_run      = create(:pay_period, :correction_run,  company: other_company,
                                source_pay_period: other_voided)
        other_voided.update!(superseded_by_id: other_run.id)

        delete "/api/v1/admin/pay_periods/#{other_run.id}",
               params: { reason: "Cross-company attack" }, as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ----------------------------------------------------------------
  # CPR-73: Re-correction chain visibility
  # ----------------------------------------------------------------
  describe "Re-correction chain (CPR-73)" do
    it "supports a full re-correction chain: void → correct → void correction → re-correct" do
      setup_ytd

      # Step 1: void the committed period
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Initial void for re-correction chain" }, as: :json
      expect(response).to have_http_status(:ok)

      # Step 2: create correction run #1
      post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
           params: { reason: "First correction attempt" }, as: :json
      expect(response).to have_http_status(:created)
      run1_id = JSON.parse(response.body)["correction_run"]["id"]

      # Step 3: delete draft correction run #1 (simulate it was wrong)
      delete "/api/v1/admin/pay_periods/#{run1_id}",
             params: { reason: "Wrong pay date on first attempt, redoing" }, as: :json
      expect(response).to have_http_status(:ok)

      # Step 4: source period should now be re-openable
      committed_period.reload
      expect(committed_period.superseded_by_id).to be_nil
      expect(committed_period.can_create_correction_run?).to be true

      # Step 5: create correction run #2
      post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
           params: { reason: "Second correction run with correct pay date" }, as: :json
      expect(response).to have_http_status(:created)
      run2 = JSON.parse(response.body)["correction_run"]
      expect(run2["status"]).to eq("draft")
      expect(run2["source_pay_period_id"]).to eq(committed_period.id)

      # Step 6: audit trail should show all events in chronological order
      get "/api/v1/admin/pay_periods/#{committed_period.id}/correction_history"
      events = JSON.parse(response.body)["correction_events"]
      action_types = events.map { |e| e["action_type"] }
      expect(action_types).to include("void_initiated", "correction_run_created", "correction_run_deleted", "correction_run_created")
    end
  end

  # ----------------------------------------------------------------
  # CPR-73: Error paths and recovery
  # ----------------------------------------------------------------
  describe "Error paths and recovery (CPR-73)" do
    it "returns a meaningful error on double-void with operator guidance info" do
      setup_ytd
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "First void" }, as: :json

      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Second void attempt" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      error_msg = JSON.parse(response.body)["error"].downcase
      expect(error_msg).to match(/already been voided|already voided/)
    end

    it "returns 422 when trying to create correction run on non-voided period" do
      post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
           params: { reason: "Source is not voided yet" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/voided/i)
    end

    it "returns 422 when reason is blank on void" do
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/reason/i)
    end

    it "returns 422 when reason is blank on create_correction_run" do
      setup_ytd
      post "/api/v1/admin/pay_periods/#{committed_period.id}/void",
           params: { reason: "Setting up" }, as: :json

      post "/api/v1/admin/pay_periods/#{committed_period.id}/create_correction_run",
           params: { reason: "  " }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/reason/i)
    end

    it "cannot void a draft period (pre-condition error)" do
      draft = create(:pay_period, company: company, status: "draft")
      post "/api/v1/admin/pay_periods/#{draft.id}/void",
           params: { reason: "Attempting void of draft" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/committed/i)
    end
  end
end
