# frozen_string_literal: true

require "rails_helper"

# Enforced-role boundary rehearsal for Track B demo-shape migration (HIGH 1):
# proves that the restricted `payroll_app` runtime role cannot invoke the
# owner-only SECURITY DEFINER conversion/revert functions AND cannot convert
# or revert a demo company via direct SQL even after setting the custom GUC.
RSpec.describe "Demo shape migration enforced runtime role boundary", :rls do
  include EnforcedRlsHelpers

  let(:connection) { ActiveRecord::Base.connection }
  let!(:organization) { create(:organization) }
  let!(:live) { create(:company, organization: organization, name: "Live Client") }
  let!(:legacy_demo) do
    create_demo_company(
      organization: organization,
      name: "Harbor Finch Kitchen",
      fixture_key: "enforced-rls-legacy"
    )
  end
  let!(:flag_demo) do
    create_live_demo_company(
      organization: organization,
      name: "Harbor Finch Flag",
      fixture_key: "enforced-rls-flag"
    )
  end

  before do
    allow(RlsContextGuard).to receive(:mode).and_return("raise")
    enforce_as_runtime_role!
  end

  it "revokes EXECUTE on conversion and revert functions from payroll_app" do
    expect(connection.select_value("SELECT current_user")).to eq("payroll_app")
    expect(
      connection.select_value("SELECT has_function_privilege('payroll_app', 'convert_demo_company_to_flag(bigint, timestamp with time zone)', 'EXECUTE')")
    ).to be(false)
    expect(
      connection.select_value("SELECT has_function_privilege('payroll_app', 'revert_demo_company_to_legacy_shape(bigint, text, bigint, timestamp with time zone, timestamp with time zone, timestamp with time zone)', 'EXECUTE')")
    ).to be(false)

    TenantScope.as_system(reason: "Attempt unauthorized demo conversion as payroll_app") do
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.select_value("SELECT convert_demo_company_to_flag(#{legacy_demo.id}, NOW())")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /permission denied for function convert_demo_company_to_flag/i)

      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.select_value("SELECT revert_demo_company_to_legacy_shape(#{flag_demo.id}, 'ready', NULL, NULL, NULL, NOW())")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /permission denied for function revert_demo_company_to_legacy_shape/i)
    end
  end

  it "blocks payroll_app from converting or reverting a demo via raw SQL even after setting the GUC" do
    expect(connection.select_value("SELECT current_user")).to eq("payroll_app")

    TenantScope.as_system(reason: "Attempt GUC-spoofed SQL conversion as payroll_app") do
      # Without GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL
            WHERE id = #{legacy_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # With spoofed convert GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL
            WHERE id = #{legacy_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # With spoofed revert GUC
      expect {
        ApplicationRecord.transaction(requires_new: true) do
          connection.execute("SET LOCAL app.demo_shape_migration_op = 'revert'")
          connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = FALSE, payroll_environment = 'migration_rehearsal', test_workspace_purpose = 'demo',
                migration_rehearsal_status = 'ready'
            WHERE id = #{flag_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      expect(legacy_demo.reload).to be_legacy_demo
      expect(flag_demo.reload[:demo]).to be(true)
      expect(flag_demo.payroll_environment).to eq("live")
    end
  end
end
