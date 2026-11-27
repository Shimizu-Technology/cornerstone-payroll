# frozen_string_literal: true

require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe DemoCompany::ConvertToFlag do
  # Exercises real top-level transactions (open_transactions == 0) so
  # ConvertToFlag / RevertToLegacyShape nested-transaction refusal,
  # SET TRANSACTION READ ONLY, and per-company commits/rollbacks run for real.
  self.use_transactional_tests = false

  let!(:created_organization_ids) { [] }
  let!(:organization) do
    create(:organization, client_limit: 2).tap { |org| created_organization_ids << org.id }
  end
  let!(:live) { create(:company, organization: organization, name: "Live Client", ein: "66-7654321") }
  let!(:sandbox) do
    create(
      :company,
      organization: organization,
      name: "Practice Copy",
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "sandbox",
      migration_source_company: live,
      migration_rehearsal_status: "ready",
      test_workspace_expires_at: 30.days.from_now
    )
  end
  let!(:admin) { create(:user, company: live, organization: organization, role: "admin", created_at: 1.year.ago) }
  let!(:old_demo) do
    create_demo_company(
      organization: organization,
      name: "Harbor Finch Kitchen",
      fixture_key: "harbor-finch-kitchen",
      subdomain_slug: "harborfinch",
      ein: "66-7654321",
      migration_rehearsal_created_by: admin,
      migration_rehearsal_created_at: Time.utc(2026, 11, 20, 10, 0, 0),
      migration_rehearsal_completed_at: Time.utc(2026, 11, 20, 10, 5, 0),
      migration_rehearsal_error: "Original legacy note preserved for exact revert"
    )
  end
  let!(:second_demo) do
    create_demo_company(
      organization: organization,
      name: "Harbor Finch Catering",
      fixture_key: "harbor-finch-catering",
      subdomain_slug: "harborfinch-catering",
      ein: "07-2026102",
      migration_rehearsal_created_by: admin,
      migration_rehearsal_created_at: Time.utc(2026, 11, 20, 10, 0, 0),
      migration_rehearsal_completed_at: Time.utc(2026, 11, 20, 10, 5, 0),
      migration_rehearsal_error: "Original legacy note preserved for exact revert"
    )
  end
  let(:employee_email) { "reviewer+hf-emp1@demo-mail.example" }
  let!(:demo_employee) do
    create(
      :employee,
      company: old_demo,
      department: create(:department, company: old_demo),
      first_name: "Employee",
      last_name: "01",
      email: employee_email,
      ssn_encrypted: "900-01-4101",
      address_line1: "100 Harbor Way",
      city: "Hagatna",
      state: "GU",
      zip: "96910",
      payment_delivery_method: "direct_deposit"
    )
  end
  let!(:portal_user) do
    create(:user, role: :portal_employee, company: old_demo, organization: organization, email: employee_email)
  end
  let!(:demo_link) do
    EmployeeAccountLink.create!(
      company: old_demo,
      employee: demo_employee,
      user: portal_user,
      status: "active",
      activated_at: 1.day.ago
    )
  end

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = employee_email
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  after do
    cleanup_organizations!(created_organization_ids)
  end

  def cleanup_organizations!(org_ids)
    ids = Array(org_ids).uniq
    return if ids.empty?

    conn = ApplicationRecord.connection
    conn.transaction do
      conn.execute("SET LOCAL session_replication_role = replica")
      company_ids = conn.select_values("SELECT id FROM companies WHERE organization_id IN (#{ids.join(',')})")
      if company_ids.any?
        c_list = company_ids.join(",")
        %w[
          employee_documents payroll_item_earnings payroll_item_deductions payroll_item_field_entries
          payroll_items pay_periods payroll_filing_events payroll_filing_records payroll_filing_responsibilities
          payroll_liability_entries payroll_liability_postings non_employee_checks time_tracking_sources
          employee_account_links company_assignments employees departments client_operating_profiles
          employee_app_activations historical_import_batches demo_shape_conversions audit_logs
        ].each do |table|
          conn.execute("DELETE FROM #{table} WHERE company_id IN (#{c_list})")
        end
      end
      o_list = ids.join(",")
      conn.execute("DELETE FROM audit_logs WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM invoice_billing_profiles WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM finance_books WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM users WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM companies WHERE organization_id IN (#{o_list})")
      conn.execute("DELETE FROM organizations WHERE id IN (#{o_list})")
    end
  end

  describe "nested transaction refusal" do
    it "refuses to run inside an existing database transaction" do
      expect {
        ApplicationRecord.transaction do
          described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: true).call
        end
      }.to raise_error(described_class::Refused, /existing database transaction/)

      expect {
        ApplicationRecord.transaction do
          described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
        end
      }.to raise_error(described_class::Refused, /existing database transaction/)
    end
  end

  describe "dry run" do
    it "writes nothing inside a READ ONLY transaction and reports only record identifiers and field names without values" do
      original_company_attrs = old_demo.reload.attributes
      original_link_attrs = demo_link.reload.attributes

      result = nil
      expect {
        result = described_class.new(
          organization: organization,
          actor: admin,
          company_ids: [ old_demo.id ],
          dry_run: true
        ).call
      }.not_to change(AuditLog, :count)

      expect(result.dry_run).to be(true)
      expect(result.converted_company_ids).to eq([ old_demo.id ])
      expect(result.already_converted_company_ids).to eq([])
      expect(old_demo.reload.attributes).to eq(original_company_attrs)
      expect(demo_link.reload.attributes).to eq(original_link_attrs)

      company_change = result.changes.find { |c| c.record_type == "company" }
      link_change = result.changes.find { |c| c.record_type == "employee_account_link" }

      expect(company_change).to have_attributes(record_id: old_demo.id, company_id: old_demo.id)
      expect(company_change.fields).to include(
        "demo",
        "payroll_environment",
        "test_workspace_purpose",
        "migration_rehearsal_status",
        "migration_rehearsal_created_by_id",
        "migration_rehearsal_created_at",
        "migration_rehearsal_completed_at"
      )
      expect(company_change.members).to eq(%i[record_type record_id company_id fields])
      expect(link_change).to have_attributes(
        record_id: demo_link.id,
        company_id: old_demo.id,
        fields: [ "payroll_environment" ]
      )
    end
  end

  def with_write_maintenance(enabled)
    saved = ENV["WRITE_MAINTENANCE"]
    ENV["WRITE_MAINTENANCE"] = enabled ? "true" : nil
    yield
  ensure
    ENV["WRITE_MAINTENANCE"] = saved
  end

  describe "apply, idempotency, and conversion-bound fenced revert" do
    it "records an append-only conversion, stays idempotent, requires WriteMaintenance to revert, and blocks invented or repeat reverts" do
      expect(old_demo).to be_legacy_demo
      expect(demo_link.payroll_environment).to eq("migration_rehearsal")

      expect(TenantSubdomainRegistry).to receive(:invalidate!).at_least(:once).and_call_original

      result = nil
      expect {
        result = described_class.new(
          organization: organization,
          actor: admin,
          company_ids: old_demo.id.to_s,
          dry_run: false
        ).call
      }.to change { AuditLog.where(action: described_class::AUDIT_ACTION, record_id: old_demo.id).count }.by(1)
        .and change { DemoShapeConversion.where(company_id: old_demo.id).count }.by(1)

      expect(result.dry_run).to be(false)
      expect(result.converted_company_ids).to eq([ old_demo.id ])
      expect(result.already_converted_company_ids).to eq([])
      conversion_id = result.conversion_ids.fetch(old_demo.id)
      expect(conversion_id).to be_a(Integer).and be_positive

      old_demo.reload
      demo_link.reload
      expect(old_demo[:demo]).to be(true)
      expect(old_demo.payroll_environment).to eq("live")
      expect(old_demo).to be_demo
      expect(old_demo).not_to be_legacy_demo
      expect(old_demo).to be_operating
      expect(old_demo).to be_contained
      expect(old_demo).not_to be_live_payroll
      expect(old_demo.test_workspace_purpose).to be_nil
      expect(old_demo.migration_rehearsal_status).to be_nil
      expect(old_demo.migration_rehearsal_created_by_id).to be_nil
      expect(old_demo.migration_rehearsal_created_at).to be_nil
      expect(old_demo.migration_rehearsal_completed_at).to be_nil
      expect(old_demo.migration_rehearsal_error).to be_nil
      expect(old_demo.migration_source_company_id).to be_nil
      expect(old_demo.migration_source_batch_id).to be_nil
      expect(old_demo.test_workspace_expires_at).to be_nil
      expect(old_demo.test_workspace_archived_at).to be_nil
      expect(old_demo.test_workspace_sealed_at).to be_nil
      expect(old_demo.test_workspace_manifest["demo_fixture_key"]).to eq("harbor-finch-kitchen")
      expect(demo_link.payroll_environment).to eq("live")

      # Re-applying is an idempotent no-op.
      company_updated_at = old_demo.updated_at
      link_updated_at = demo_link.updated_at
      rerun = nil
      expect {
        rerun = described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
      }.not_to change(AuditLog, :count)
      expect(rerun.converted_company_ids).to eq([])
      expect(rerun.already_converted_company_ids).to eq([ old_demo.id ])
      expect(rerun.conversion_ids).to eq({})
      expect(rerun.changes).to be_empty
      expect(old_demo.reload.updated_at).to eq(company_updated_at)
      expect(demo_link.reload.updated_at).to eq(link_updated_at)

      # Revert REFUSES unless WriteMaintenance is enabled (both service and SQL helper).
      with_write_maintenance(false) do
        expect {
          DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id, dry_run: false
          ).call
        }.to raise_error(DemoCompany::RevertToLegacyShape::Refused, /WriteMaintenance must be enabled/)
      end
      expect {
        ApplicationRecord.transaction do
          ApplicationRecord.connection.select_value(
            "SELECT revert_demo_company_to_legacy_shape(#{conversion_id}, #{admin.id}, false, NOW())"
          )
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /requires WriteMaintenance to be enabled/)

      # Revert REFUSES for a nonexistent conversion ID (a never-converted flag demo cannot be reverted).
      never_converted_flag = create_live_demo_company(organization: organization, name: "Never Converted Flag", fixture_key: "never-converted-flag")
      expect(DemoShapeConversion.where(company_id: never_converted_flag.id)).to be_empty
      with_write_maintenance(true) do
        expect {
          DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id + 99_999, dry_run: false
          ).call
        }.to raise_error(DemoCompany::RevertToLegacyShape::Refused, /not found/)
      end

      # Direct tampering with demo_shape_conversions is refused by DB trigger.
      expect {
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute(
            "DELETE FROM demo_shape_conversions WHERE id = #{conversion_id}"
          )
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)

      # Targeted per-company revert under WriteMaintenance restores exact recorded legacy shape without touching live client.
      live_updated_at = live.reload.updated_at
      with_write_maintenance(true) do
        revert_dry = DemoCompany::RevertToLegacyShape.new(
          organization: organization, actor: admin, conversion_id: conversion_id, dry_run: true
        ).call
        expect(revert_dry).to have_attributes(dry_run: true, conversion_id: conversion_id, company_id: old_demo.id, links_reverted: 1)
        expect(old_demo.reload[:demo]).to be(true)

        revert_applied = nil
        expect {
          revert_applied = DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id, dry_run: false
          ).call
        }.to change { AuditLog.where(action: DemoCompany::RevertToLegacyShape::AUDIT_ACTION, record_id: old_demo.id).count }.by(1)

        expect(revert_applied).to have_attributes(dry_run: false, conversion_id: conversion_id, company_id: old_demo.id, links_reverted: 1)

        # Repeat revert on an already-reverted conversion is refused.
        expect {
          DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id, dry_run: false
          ).call
        }.to raise_error(DemoCompany::RevertToLegacyShape::Refused, /already been reverted/)
      end

      old_demo.reload
      expect(old_demo[:demo]).to be(false)
      expect(old_demo.payroll_environment).to eq("migration_rehearsal")
      expect(old_demo.test_workspace_purpose).to eq("demo")
      expect(old_demo.migration_rehearsal_status).to eq("ready")
      expect(old_demo.migration_rehearsal_created_by_id).to eq(admin.id)
      expect(old_demo.migration_rehearsal_created_at).to eq(Time.utc(2026, 11, 20, 10, 0, 0))
      expect(old_demo.migration_rehearsal_completed_at).to eq(Time.utc(2026, 11, 20, 10, 5, 0))
      expect(old_demo.migration_rehearsal_error).to eq("Original legacy note preserved for exact revert")
      expect(demo_link.reload.payroll_environment).to eq("migration_rehearsal")
      expect(live.reload.updated_at).to eq(live_updated_at)
      expect(DemoShapeConversion.find(conversion_id)).to be_reverted
    end

    it "refuses revert when current company shape or manifest differs from what the conversion wrote" do
      result = described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
      conversion_id = result.conversion_ids.fetch(old_demo.id)

      # Mutate a non-fixture-key manifest field so current shape differs from recorded after_company_shape.
      old_demo.reload.update_columns(
        test_workspace_manifest: old_demo.test_workspace_manifest.merge("post_conversion_note" => "drifted")
      )

      with_write_maintenance(true) do
        expect {
          DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id, dry_run: false
          ).call
        }.to raise_error(DemoCompany::RevertToLegacyShape::Refused, /differs from what the conversion wrote/)
      end
    end

    it "lifts filing/liability/non-employee check triggers after conversion, blocks revert once lifted rows exist, and keeps time_tracking_sources refused" do
      result = described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
      conversion_id = result.conversion_ids.fetch(old_demo.id)
      old_demo.reload

      period = create_committed_demo_pay_period(company: old_demo, pay_date: Date.new(2026, 3, 6), employee: demo_employee)
      PayrollFilingResponsibilityRecorder.new(
        company: old_demo, actor: admin, tax_year: 2026, filing_types: %w[w2_gu],
        responsible_party: "cornerstone", imported_payroll_inclusion: "included", prior_provider_through: nil
      ).call

      expect(PayrollLiabilityPostingService.post!(pay_period: period, actor: admin)).to be_persisted
      expect(NonEmployeeCheck.create!(
        company: old_demo, pay_period: period, payable_to: "Treasurer of Guam", amount: 150,
        check_type: "tax_deposit", payment_period_type: "pay_period", payment_date: period.pay_date, created_by: admin
      )).to be_persisted
      expect(PayrollFilingRecord.create!(
        company: old_demo, filing_type: "w2_gu_w3_ss", agency: "ssa", tax_year: 2026,
        status: "submitted", submitted_at: Time.current, confirmation_number: "DEMO-CONF", source_fingerprint: "a" * 64
      )).to be_persisted

      # Reverting is refused once post-conversion filing/liability/non-employee-check rows exist.
      with_write_maintenance(true) do
        expect {
          DemoCompany::RevertToLegacyShape.new(
            organization: organization, actor: admin, conversion_id: conversion_id, dry_run: false
          ).call
        }.to raise_error(DemoCompany::RevertToLegacyShape::Refused, /post-conversion/)
      end

      # Time tracking sources remain refused in both the model and the database trigger.
      expect(build(:time_tracking_source, company: old_demo)).not_to be_valid
      expect {
        ActiveRecord::Base.transaction do
          TimeTrackingSource.insert_all!([ {
            company_id: old_demo.id, name: "Blocked AIRE", source_type: "aire_services",
            base_url: "https://aire.example.test", shared_secret: "secret", active: true,
            created_at: Time.current, updated_at: Time.current
          } ])
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /time_tracking_sources cannot belong to a demo company/)
    end
  end

  describe "refusals and authorization" do
    it "refuses a real live company, a practice copy, an out-of-org demo, and mixed batches before writing anything" do
      other_org = create(:organization).tap { |org| created_organization_ids << org.id }
      other_demo = create_demo_company(organization: other_org, fixture_key: "other-org-demo")

      [ live.id, sandbox.id, other_demo.id, [ old_demo.id, live.id ], [], "" ].each do |ids|
        expect {
          described_class.new(organization: organization, actor: admin, company_ids: ids, dry_run: false).call
        }.to raise_error(described_class::Refused)
      end

      expect(live.reload.demo?).to be(false)
      expect(sandbox.reload.demo?).to be(false)
      expect(old_demo.reload).to be_legacy_demo
      expect(demo_link.reload.payroll_environment).to eq("migration_rehearsal")
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end

    it "refuses non-demo migration_rehearsal, backup_snapshot, and sandbox companies individually and in mixed batches" do
      locked_batch = create(:historical_import_batch, company: live, status: "locked")
      rehearsal_copy = create(
        :company,
        organization: organization,
        name: "Client Migration Rehearsal",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "migration_rehearsal",
        migration_source_company: live,
        migration_source_batch: locked_batch,
        migration_rehearsal_status: "ready"
      )
      backup_snapshot = create(
        :company,
        organization: organization,
        name: "Client Backup Snapshot",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "backup_snapshot",
        migration_source_company: live,
        migration_rehearsal_status: "ready",
        test_workspace_sealed_at: Time.current
      )

      [ rehearsal_copy, backup_snapshot, sandbox ].each do |non_demo|
        expect {
          described_class.new(organization: organization, actor: admin, company_ids: [ non_demo.id ], dry_run: true).call
        }.to raise_error(described_class::Refused, /not an old-shape demo company/)

        expect {
          described_class.new(organization: organization, actor: admin, company_ids: [ non_demo.id ], dry_run: false).call
        }.to raise_error(described_class::Refused, /not an old-shape demo company/)

        expect {
          described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id, non_demo.id ], dry_run: false).call
        }.to raise_error(described_class::Refused, /not an old-shape demo company/)
      end

      expect(rehearsal_copy.reload).to have_attributes(
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "migration_rehearsal",
        demo: false
      )
      expect(backup_snapshot.reload).to have_attributes(
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "backup_snapshot",
        demo: false
      )
      expect(sandbox.reload).to have_attributes(
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "sandbox",
        demo: false
      )
      expect(old_demo.reload).to be_legacy_demo
      expect(demo_link.reload.payroll_environment).to eq("migration_rehearsal")
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end

    it "requires an active organization administrator of the same organization" do
      accountant = create(:user, company: live, organization: organization, role: "accountant")
      manager = create(:user, company: live, organization: organization, role: "manager")
      inactive_admin = create(:user, company: live, organization: organization, role: "admin", active: false)
      other_org = create(:organization).tap { |org| created_organization_ids << org.id }
      other_company = create(:company, organization: other_org)
      outsider_admin = create(:user, company: other_company, organization: other_org, role: "admin")

      [ accountant, manager, inactive_admin, outsider_admin, nil ].each do |bad_actor|
        expect {
          described_class.new(organization: organization, actor: bad_actor, company_ids: [ old_demo.id ], dry_run: false).call
        }.to raise_error(described_class::Refused, /organization administrator/)
      end

      expect(old_demo.reload).to be_legacy_demo
    end

    it "refuses before any write if a requested company leaves the organization between validation and query" do
      other_org = create(:organization).tap { |org| created_organization_ids << org.id }

      # Dry-run: company moves out right after validate_targets_before_write!.
      service_dry = described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id, second_demo.id ], dry_run: true)
      allow(service_dry).to receive(:validate_targets_before_write!).and_wrap_original do |orig|
        orig.call
        second_demo.update_columns(organization_id: other_org.id)
      end
      expect { service_dry.call }.to raise_error(described_class::Refused, /not found in organization: #{second_demo.id}/)

      # Restore and test apply mode: neither company may be written.
      second_demo.update_columns(organization_id: organization.id)
      service_apply = described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id, second_demo.id ], dry_run: false)
      allow(service_apply).to receive(:validate_targets_before_write!).and_wrap_original do |orig|
        orig.call
        second_demo.update_columns(organization_id: other_org.id)
      end
      expect { service_apply.call }.to raise_error(described_class::Refused, /not found in organization: #{second_demo.id}/)
      expect(old_demo.reload).to be_legacy_demo
      expect(second_demo.reload).to be_legacy_demo
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end
  end

  describe "atomic rollback on half-failure" do
    it "rolls back a half-failed company completely while preserving already-committed prior companies" do
      allow(AuditLog).to receive(:record!).and_call_original
      allow(AuditLog).to receive(:record!).with(hash_including(company_id: second_demo.id))
        .and_raise(RuntimeError, "simulated audit failure")

      second_employee = create(:employee, company: second_demo, department: create(:department, company: second_demo), ssn_encrypted: "900-01-4202")
      second_link = EmployeeAccountLink.create!(
        company: second_demo, employee: second_employee, user: portal_user, status: "active", activated_at: 1.day.ago
      )

      expect {
        described_class.new(
          organization: organization,
          actor: admin,
          company_ids: [ old_demo.id, second_demo.id ],
          dry_run: false
        ).call
      }.to raise_error(RuntimeError, /simulated audit failure/)

      expect(old_demo.reload[:demo]).to be(true)
      expect(old_demo.payroll_environment).to eq("live")
      expect(demo_link.reload.payroll_environment).to eq("live")

      expect(second_demo.reload[:demo]).to be(false)
      expect(second_demo.payroll_environment).to eq("migration_rehearsal")
      expect(second_demo.test_workspace_purpose).to eq("demo")
      expect(second_demo.migration_rehearsal_status).to eq("ready")
      expect(second_link.reload.payroll_environment).to eq("migration_rehearsal")
      expect(AuditLog.where(action: described_class::AUDIT_ACTION, record_id: second_demo.id)).to be_empty
    end
  end

  describe "database trigger guardrails (HIGH 1 NULL-safe GUC + MEDIUM 3 manifest/fixture-key immutability)" do
    def raw_sql(sql)
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute(sql)
      end
    end

    it "rejects direct SQL conversion when the GUC is unset (NULL), rejects forbidden transitions, and blocks keyless fixture-key acquisition or manifest edits" do
      # Use a brand-new PG connection so app.demo_shape_migration_op is genuinely absent (NULL).
      raw_conn = PG.connect(ActiveRecord::Base.connection_db_config.url)
      begin
        expect(raw_conn.exec("SELECT current_setting('app.demo_shape_migration_op', true)").getvalue(0, 0)).to be_nil

        expect {
          raw_conn.exec(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
                migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL
            WHERE id = #{second_demo.id}
          SQL
        }.to raise_error(PG::CheckViolation, /demo companies cannot be converted/)
      ensure
        raw_conn.close
      end

      # Even with op='convert', converting a real live client to demo is refused.
      expect {
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          ActiveRecord::Base.connection.execute("UPDATE companies SET demo = TRUE WHERE id = #{live.id}")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even with op='convert', converting a legacy demo to a real live client (demo=false) is refused.
      expect {
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = FALSE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
                migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL
            WHERE id = #{second_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even with op='convert', changing ANY manifest key (not only demo_fixture_key) during conversion is refused.
      expect {
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL app.demo_shape_migration_op = 'convert'")
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
                migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL,
                test_workspace_manifest = '{"version":1,"purpose":"demo","demo_fixture_key":"harbor-finch-catering","extra":"tampered"}'::jsonb
            WHERE id = #{second_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # A keyless demo cannot acquire a demo_fixture_key later (NULL -> non-NULL).
      keyless_demo = create_live_demo_company(organization: organization, name: "Keyless Demo", fixture_key: nil)
      expect {
        raw_sql(<<~SQL.squish)
          UPDATE companies
          SET test_workspace_manifest = '{"demo_fixture_key":"acquired-key"}'::jsonb
          WHERE id = #{keyless_demo.id}
        SQL
      }.to raise_error(ActiveRecord::StatementInvalid, /demo fixture keys are immutable/)
    end
  end

  describe "payroll checksum and posted-stub stability hazards" do
    let(:stored_pdfs) { {} }
    let(:storage) { instance_double(R2StorageService) }

    before do
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow(storage).to receive(:upload) { |key, bytes, **| stored_pdfs[key] = bytes.dup.b }
      allow(storage).to receive(:download) { |key| stored_pdfs[key] }
      allow(storage).to receive(:delete) { |key| stored_pdfs.delete(key) }
    end

    it "keeps CalculationSnapshot, PayrollItemLegacyDispositionService, and posted EmployeeDocument stubs unchanged without re-posting" do
      period = create_committed_demo_pay_period(company: old_demo, pay_date: PayrollBusinessClock.today - 3, employee: demo_employee)
      period.update_columns(committed_at: 2.days.ago)
      item = period.payroll_items.sole
      item.update_columns(payment_delivery_method: "direct_deposit")

      posted_doc = EmployeeDocuments::PostPayStub.new(item, now: Time.current).call
      expect(posted_doc).to be_persisted
      expect(posted_doc.status).to eq("posted")
      expect(posted_doc.revision).to eq(1)

      before_calc_checksum = PayrollReview::CalculationSnapshot.new(pay_period: period).call.fetch(:checksum)
      before_legacy_digest = PayrollItemLegacyDispositionService.digest_for(item)
      before_stub_fingerprint = PayStubGenerator.new(item, employee_copy: true).employee_payroll_facts_sha256

      described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call

      period.reload
      item.reload
      expect(PayrollReview::CalculationSnapshot.new(pay_period: period).call.fetch(:checksum)).to eq(before_calc_checksum)
      expect(PayrollItemLegacyDispositionService.digest_for(item)).to eq(before_legacy_digest)
      expect(PayStubGenerator.new(item, employee_copy: true).employee_payroll_facts_sha256).to eq(before_stub_fingerprint)
      expect(PayStubGenerator.new(item, employee_copy: true).matches_employee_payroll_facts?(posted_doc.payroll_facts_sha256)).to be(true)

      expect {
        EmployeeDocuments::PostPayStub.new(item, now: Time.current).call
      }.not_to change(EmployeeDocument, :count)
      expect(posted_doc.reload.status).to eq("posted")
      expect(posted_doc.revision).to eq(1)
    end
  end

  describe "rake demo:convert_to_flag and demo:revert_to_legacy_shape" do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:convert_to_flag")
    end

    def run_task(name, env_vars)
      keys = %w[ORGANIZATION_ID ACTOR_ID COMPANY_IDS CONVERSION_ID APPLY WRITE_MAINTENANCE MIGRATION_DATABASE_URL]
      previous = ENV.to_h.slice(*keys)
      keys.each { |k| ENV.delete(k) }
      env_vars.each { |k, v| ENV[k] = v }
      Rake::Task[name].reenable
      Rake::Task[name].invoke
    ensure
      keys.each { |k| ENV[k] = previous[k] }
    end

    it "runs dry-run without values, converts on APPLY=true, stays idempotent, and reverts by CONVERSION_ID under WriteMaintenance and strict RLS" do
      allow(RlsContextGuard).to receive(:mode).and_return("raise")

      expect {
        RlsSpecContext.strict { run_task("demo:convert_to_flag", "ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s) }
      }.to output(
        a_string_including(
          "PLAN  company id=#{old_demo.id} company_id=#{old_demo.id} fields=",
          "PLAN  employee_account_link id=#{demo_link.id} company_id=#{old_demo.id} fields=payroll_environment",
          "OK    demo:convert_to_flag mode=dry_run converted=#{old_demo.id} already_converted=none conversions=none"
        ).and(satisfy { |out| !out.include?("Harbor Finch") && !out.include?("harbor-finch-kitchen") && !/\bready\b/.match?(out) && !out.include?("66-7654321") })
      ).to_stdout

      expect {
        RlsSpecContext.strict { run_task("demo:convert_to_flag", "ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "APPLY" => "true") }
      }.to output(/OK    demo:convert_to_flag mode=applied converted=#{old_demo.id} already_converted=none conversions=#{old_demo.id}:\d+/).to_stdout

      conversion_id = TenantScope.as_system(reason: "Read recorded conversion id") do
        DemoShapeConversion.active.find_by!(company_id: old_demo.id).id
      end

      expect {
        RlsSpecContext.strict { run_task("demo:convert_to_flag", "ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "APPLY" => "true") }
      }.to output(/OK    demo:convert_to_flag mode=applied converted=none already_converted=#{old_demo.id} conversions=none changes=0/).to_stdout

      expect {
        RlsSpecContext.strict do
          run_task("demo:revert_to_legacy_shape",
            "ACTOR_ID" => admin.id.to_s, "CONVERSION_ID" => conversion_id.to_s, "WRITE_MAINTENANCE" => "true", "APPLY" => "true")
        end
      }.to output(/OK    demo:revert_to_legacy_shape mode=applied conversion_id=#{conversion_id} company_id=#{old_demo.id} links_reverted=1/).to_stdout

      TenantScope.as_system(reason: "Verify reverted company") do
        expect(old_demo.reload).to be_legacy_demo
        expect(demo_link.reload.payroll_environment).to eq("migration_rehearsal")
      end
    end

    it "aborts with FAIL when demo:convert_to_flag is given a migration_rehearsal, backup_snapshot, or sandbox company" do
      locked_batch = create(:historical_import_batch, company: live, status: "locked")
      rehearsal_copy = create(
        :company,
        organization: organization,
        name: "Rake Rehearsal Copy",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "migration_rehearsal",
        migration_source_company: live,
        migration_source_batch: locked_batch,
        migration_rehearsal_status: "ready"
      )
      backup_snapshot = create(
        :company,
        organization: organization,
        name: "Rake Backup Snapshot",
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "backup_snapshot",
        migration_source_company: live,
        migration_rehearsal_status: "ready",
        test_workspace_sealed_at: Time.current
      )

      [ rehearsal_copy, backup_snapshot, sandbox ].each do |non_demo|
        expect {
          run_task("demo:convert_to_flag", "ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => non_demo.id.to_s, "APPLY" => "true")
        }.to raise_error(SystemExit).and output(/FAIL  demo:convert_to_flag Refusing to convert company ##{non_demo.id}/).to_stderr
        expect(non_demo.reload[:demo]).to be(false)
        expect(non_demo.payroll_environment).to eq("migration_rehearsal")
      end
      expect(AuditLog.where(action: described_class::AUDIT_ACTION)).to be_empty
    end
  end
end
