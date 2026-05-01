require "rails_helper"

RSpec.describe "Api::V1::Admin::NonEmployeeChecks", type: :request do
  let!(:company) { create(:company) }
  let!(:other_company) { create(:company) }
  let!(:pay_period) { create(:pay_period, company: company) }
  let!(:other_pay_period) { create(:pay_period, company: other_company) }
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "non-employee-checks-admin@example.com",
      name: "Checks Admin",
      role: "admin",
      active: true
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController).to receive(:current_user).and_return(admin_user)
  end

  describe "POST /api/v1/admin/non_employee_checks" do
    let(:valid_params) do
      {
        non_employee_check: {
          pay_period_id: pay_period.id,
          payable_to: "Island Vendor",
          amount: 125.50,
          check_type: "vendor",
          memo: "Office supplies"
        }
      }
    end

    it "creates a check for the current company pay period" do
      expect {
        post "/api/v1/admin/non_employee_checks", params: valid_params, as: :json
      }.to change(NonEmployeeCheck, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(NonEmployeeCheck.last.pay_period_id).to eq(pay_period.id)
      expect(NonEmployeeCheck.last.payment_period_type).to eq("pay_period")
    end

    it "creates a standalone GRT check without a pay period" do
      expect {
        post "/api/v1/admin/non_employee_checks",
          params: {
            non_employee_check: {
              payable_to: "Treasurer of Guam",
              amount: 425.75,
              check_type: "grt",
              payment_period_type: "month",
              tax_year: 2026,
              tax_month: 3,
              due_date: "2026-04-20",
              payment_date: "2026-04-18",
              confirmation_number: "GRT-12345",
              memo: "March GRT"
            }
          },
          as: :json
      }.to change(NonEmployeeCheck, :count).by(1)

      expect(response).to have_http_status(:created)
      check = NonEmployeeCheck.last
      expect(check.pay_period_id).to be_nil
      expect(check.check_type).to eq("grt")
      expect(check.payment_period_type).to eq("month")
      expect(check.tax_year).to eq(2026)
      expect(check.tax_month).to eq(3)
      expect(check.confirmation_number).to eq("GRT-12345")
      expect(response.parsed_body.dig("non_employee_check", "pay_period_id")).to be_nil
    end

    it "clears hidden stale tax period fields that do not match the selected period type" do
      post "/api/v1/admin/non_employee_checks",
        params: {
          non_employee_check: {
            payable_to: "Treasurer of Guam",
            amount: 425.75,
            check_type: "grt",
            payment_period_type: "month",
            tax_year: 2026,
            tax_month: 3,
            tax_quarter: 2
          }
        },
        as: :json

      expect(response).to have_http_status(:created)
      check = NonEmployeeCheck.last
      expect(check.tax_month).to eq(3)
      expect(check.tax_quarter).to be_nil
    end

    it "validates required tax period fields for standalone monthly payments" do
      expect {
        post "/api/v1/admin/non_employee_checks",
          params: {
            non_employee_check: {
              payable_to: "Treasurer of Guam",
              amount: 425.75,
              check_type: "grt",
              payment_period_type: "month"
            }
          },
          as: :json
      }.not_to change(NonEmployeeCheck, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join(", ")).to match(/Tax year|Tax month/)
    end

    it "rejects a pay period from another company on create" do
      expect {
        post "/api/v1/admin/non_employee_checks",
          params: {
            non_employee_check: valid_params[:non_employee_check].merge(pay_period_id: other_pay_period.id)
          },
          as: :json
      }.not_to change(NonEmployeeCheck, :count)

      expect(response).to have_http_status(:not_found)
    end

    it "filters standalone checks separately from pay-period checks" do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Payroll Vendor",
        amount: 50.00,
        check_type: "vendor",
        payment_period_type: "pay_period"
      )
      standalone = NonEmployeeCheck.create!(
        company: company,
        created_by: admin_user,
        payable_to: "Treasurer of Guam",
        amount: 425.75,
        check_type: "grt",
        payment_period_type: "month",
        tax_year: 2026,
        tax_month: 3
      )

      get "/api/v1/admin/non_employee_checks", params: { standalone: "true" }

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["non_employee_checks"].map { |row| row["id"] }
      expect(ids).to eq([ standalone.id ])
    end

    it "returns 422 instead of 500 for malformed date filters" do
      get "/api/v1/admin/non_employee_checks", params: { from: "04/30/2026" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("from must be an ISO-8601 date")
    end
  end

  describe "PATCH /api/v1/admin/non_employee_checks/:id" do
    let!(:check) do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Island Vendor",
        amount: 125.50,
        check_type: "vendor",
        memo: "Office supplies"
      )
    end

    # Regression test for the missing model-level uniqueness validation on
    # check_number. The DB has a partial unique index but without the model
    # validation a duplicate value would raise ActiveRecord::RecordNotUnique
    # and surface as a 500 instead of a clean 422 with field errors.
    it "returns 422 (not 500) when check_number is already used in the same company" do
      existing = NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Other Vendor",
        amount: 50.00,
        check_type: "vendor",
        check_number: "1001"
      )

      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { check_number: existing.check_number }
        },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect((json["errors"] || [json["error"]]).join(", ")).to match(/check number/i)
    end

    # Regression test: editing two unrelated checks without a check number
    # in the same company used to hit the partial unique index because the
    # modal sent check_number: "" (which Postgres treats as NOT NULL),
    # causing the second save to raise ActiveRecord::RecordNotUnique → 500.
    # The controller now coerces blank → nil so each unset row is NULL and
    # the partial index ignores them.
    it "allows multiple blank-check_number edits in the same company without 500ing" do
      other_check = NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Other Vendor",
        amount: 75.00,
        check_type: "vendor"
      )

      # First blank-check edit — works.
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: { non_employee_check: { check_number: "", memo: "first edit" } },
        as: :json
      expect(response).to have_http_status(:ok)
      expect(check.reload.check_number).to be_nil

      # Second blank-check edit on a *different* check in the same company —
      # would previously raise ActiveRecord::RecordNotUnique on the partial
      # index. Now stays NULL on both rows and saves cleanly.
      patch "/api/v1/admin/non_employee_checks/#{other_check.id}",
        params: { non_employee_check: { check_number: "", memo: "second edit" } },
        as: :json
      expect(response).to have_http_status(:ok)
      expect(other_check.reload.check_number).to be_nil
      expect(other_check.reload.memo).to eq("second edit")
    end

    it "treats whitespace-only check_number as blank (coerced to nil)" do
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: { non_employee_check: { check_number: "   " } },
        as: :json

      expect(response).to have_http_status(:ok)
      expect(check.reload.check_number).to be_nil
    end

    it "allows the same check_number in a different company" do
      NonEmployeeCheck.create!(
        company: other_company,
        pay_period: other_pay_period,
        created_by: admin_user,
        payable_to: "Other Co Vendor",
        amount: 99.00,
        check_type: "vendor",
        check_number: "2002"
      )

      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { check_number: "2002" }
        },
        as: :json

      expect(response).to have_http_status(:ok)
      expect(check.reload.check_number).to eq("2002")
    end

    it "rejects a check_number already used by a payroll check" do
      employee = create(:employee, company: company)
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        check_number: "2468"
      )

      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { check_number: "2468" }
        },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("payroll check")
      expect(check.reload.check_number).to be_nil
    end

    it "syncs saved transmittal non-employee check numbers" do
      Transmittal.create!(
        pay_period: pay_period,
        company: company,
        non_employee_check_numbers: { check.id.to_s => "1001" }
      )

      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { check_number: "2469" },
          reason: "Actual non-employee check stock used"
        },
        as: :json

      expect(response).to have_http_status(:ok)
      expect(pay_period.transmittal.reload.non_employee_check_numbers[check.id.to_s]).to eq("2469")
    end

    it "does not try to sync a transmittal when a check has no pay period" do
      controller = Api::V1::Admin::NonEmployeeChecksController.new
      check_without_period = instance_double(NonEmployeeCheck, pay_period: nil)

      expect {
        controller.send(:sync_transmittal_check_number!, check_without_period)
      }.not_to raise_error
    end

    it "advances next_check_number when assigning a higher non-employee check number" do
      company.update!(next_check_number: 2000)

      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { check_number: "2469" }
        },
        as: :json

      expect(response).to have_http_status(:ok)
      expect(company.reload.next_check_number).to eq(2470)
    end

    it "rejects changing the pay period to another company" do
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: { pay_period_id: other_pay_period.id }
        },
        as: :json

      expect(response).to have_http_status(:not_found)
      expect(check.reload.pay_period_id).to eq(pay_period.id)
    end

    it "can detach from a pay period and reclassify as a monthly standalone check in one update" do
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: {
            pay_period_id: nil,
            payment_period_type: "month",
            tax_year: 2026,
            tax_month: 4
          }
        },
        as: :json

      expect(response).to have_http_status(:ok)
      check.reload
      expect(check.pay_period_id).to be_nil
      expect(check.payment_period_type).to eq("month")
      expect(check.tax_year).to eq(2026)
      expect(check.tax_month).to eq(4)
    end

    it "creates an audit log entry capturing changed fields and reason" do
      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: {
            non_employee_check: { payable_to: "Island Vendor LLC", amount: 200.00 },
            reason: "Vendor renamed and invoice updated"
          },
          as: :json
      }.to change(NonEmployeeCheckEdit, :count).by(1)

      expect(response).to have_http_status(:ok)

      edit = NonEmployeeCheckEdit.last
      expect(edit.changed_fields).to match_array(%w[payable_to amount])
      expect(edit.before["payable_to"]).to eq("Island Vendor")
      expect(edit.after["payable_to"]).to eq("Island Vendor LLC")
      expect(edit.before["amount"]).to eq("125.5")
      expect(edit.after["amount"]).to eq("200.0")
      expect(edit.reason).to eq("Vendor renamed and invoice updated")
      expect(edit.edited_by_id).to eq(admin_user.id)
    end

    it "does not create an audit entry when no audited fields actually change" do
      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: { non_employee_check: { payable_to: check.payable_to } },
          as: :json
      }.not_to change(NonEmployeeCheckEdit, :count)
    end

    # Regression for the nil → "" spurious-audit issue (Greptile P2 / data
    # quality). The Edit modal sends the full payload, so unset optional
    # text fields arrive as "". Without coercion, the DB column flips
    # nil → "" on a no-op edit and the diff records a phantom change like
    # `{description: null → ""}`. Both `check_params` (controller) and
    # `changed_fields` (audit comparator) now treat blank and nil as
    # equivalent for these fields.
    it "treats nil and blank optional-text fields as equivalent (no spurious audit entry)" do
      # `check` was created with description=nil/reference_number=nil,
      # but the modal will send "" for both on every save. Touch only
      # one real field so we can confirm the audit log lists *only*
      # that one and not the phantom blanks.
      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: {
            non_employee_check: {
              payable_to:        check.payable_to,
              amount:            check.amount.to_s,
              check_type:        check.check_type,
              memo:              check.memo,                # unchanged
              description:       "",                        # was nil — should NOT diff
              reference_number:  "",                        # was nil — should NOT diff
              confirmation_number: "",                      # was nil — should NOT diff
              check_number:      ""                         # was nil — should NOT diff
            },
            reason: "Touching payable_to only"
          },
          as: :json
      }.not_to change(NonEmployeeCheckEdit, :count)

      # And the DB stays nil (not coerced to "") so future audit diffs
      # don't degrade either.
      check.reload
      expect(check.description).to be_nil
      expect(check.reference_number).to be_nil
      expect(check.confirmation_number).to be_nil
      expect(check.check_number).to be_nil
    end

    it "logs only real changes when blanks-vs-nils coexist with a genuine edit" do
      patch "/api/v1/admin/non_employee_checks/#{check.id}",
        params: {
          non_employee_check: {
            payable_to:       "Updated Vendor Name",
            description:      "",
            reference_number: "",
            check_number:     ""
          },
          reason: "Renamed vendor"
        },
        as: :json

      expect(response).to have_http_status(:ok)
      edit = check.edits.order(created_at: :desc).first
      expect(edit.changed_fields).to eq([ "payable_to" ])
      # While we're here, assert the reason actually lands. The previous
      # version of this spec passed `edit_reason:` *inside*
      # `non_employee_check:` (the strong-params permitted scope), which
      # was silently dropped because the controller reads
      # `params[:reason]` at the top level. Locking the round-trip in.
      expect(edit.reason).to eq("Renamed vendor")
    end

    it "rejects updates to a voided check" do
      check.update!(voided: true, voided_at: Time.current, void_reason: "test")

      expect {
        patch "/api/v1/admin/non_employee_checks/#{check.id}",
          params: { non_employee_check: { amount: 50.00 } },
          as: :json
      }.not_to change(NonEmployeeCheckEdit, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "DELETE /api/v1/admin/non_employee_checks/:id" do
    let!(:check) do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Island Vendor",
        amount: 125.50,
        check_type: "vendor"
      )
    end

    # Regression test for the dependent: :destroy / readonly? conflict —
    # NonEmployeeCheckEdit#readonly? is true once persisted, so the prior
    # `dependent: :destroy` raised ActiveRecord::ReadOnlyRecord on delete.
    it "deletes a check that has audit edits without raising ReadOnlyRecord" do
      check.edits.create!(
        edited_by: admin_user,
        before: { "amount" => "125.5" },
        after: { "amount" => "150.0" },
        changed_fields: ["amount"]
      )

      expect {
        delete "/api/v1/admin/non_employee_checks/#{check.id}"
      }.to change(NonEmployeeCheck, :count).by(-1)
        .and change(NonEmployeeCheckEdit, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/admin/non_employee_checks/:id/history" do
    let!(:check) do
      NonEmployeeCheck.create!(
        company: company,
        pay_period: pay_period,
        created_by: admin_user,
        payable_to: "Island Vendor",
        amount: 125.50,
        check_type: "vendor"
      )
    end

    it "returns the edits for the check, newest first" do
      check.edits.create!(
        edited_by: admin_user,
        before: { "amount" => "125.5" },
        after: { "amount" => "150.0" },
        changed_fields: ["amount"],
        reason: "Older edit"
      )
      check.edits.create!(
        edited_by: admin_user,
        before: { "amount" => "150.0" },
        after: { "amount" => "175.0" },
        changed_fields: ["amount"],
        reason: "Newer edit"
      )

      get "/api/v1/admin/non_employee_checks/#{check.id}/history"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["history"].length).to eq(2)
      expect(json["history"].first["reason"]).to eq("Newer edit")
      expect(json["history"].last["reason"]).to eq("Older edit")
    end
  end
end
