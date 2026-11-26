# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe DemoCompany::ConvertToFlag do
  let!(:organization) { create(:organization, client_limit: 2) }
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
      migration_rehearsal_created_at: 2.days.ago,
      migration_rehearsal_completed_at: 2.days.ago
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
      migration_rehearsal_created_at: 2.days.ago,
      migration_rehearsal_completed_at: 2.days.ago
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

  describe "dry run" do
    it "writes nothing and reports only record identifiers and field names without values" do
      original_company_attrs = old_demo.reload.attributes
      original_link_attrs = demo_link.reload.attributes

      result = expect {
        described_class.new(
          organization: organization,
          actor: admin,
          company_ids: [ old_demo.id ],
          dry_run: true
        ).call
      }.not_to change(AuditLog, :count)

      # Re-run to capture the returned Result cleanly.
      result = described_class.new(
        organization: organization,
        actor: admin,
        company_ids: [ old_demo.id ],
        dry_run: true
      ).call

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

  describe "apply and idempotency" do
    it "converts an old-shape demo and its employee-app links atomically, writes an audit row, and is idempotent" do
      expect(old_demo).to be_legacy_demo
      expect(demo_link.payroll_environment).to eq("migration_rehearsal")
      expect(TenantSubdomainRegistry).to receive(:invalidate!).once.and_call_original

      result = nil
      expect {
        result = described_class.new(
          organization: organization,
          actor: admin,
          company_ids: "#{old_demo.id}",
          dry_run: false
        ).call
      }.to change { AuditLog.where(action: described_class::AUDIT_ACTION, record_id: old_demo.id).count }.by(1)

      expect(result.dry_run).to be(false)
      expect(result.converted_company_ids).to eq([ old_demo.id ])
      expect(result.already_converted_company_ids).to eq([])

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

      audit = AuditLog.find_by!(action: described_class::AUDIT_ACTION, record_id: old_demo.id)
      expect(audit.user_id).to eq(admin.id)
      expect(audit.organization_id).to eq(organization.id)
      expect(audit.company_id).to eq(old_demo.id)
      expect(audit.metadata["fixture_key"]).to eq("harbor-finch-kitchen")
      expect(audit.metadata["employee_account_links_updated"]).to eq(1)

      # Re-applying is a strict idempotent no-op with zero writes and zero extra audits.
      company_updated_at = old_demo.updated_at
      link_updated_at = demo_link.updated_at
      rerun = nil
      expect {
        rerun = described_class.new(
          organization: organization,
          actor: admin,
          company_ids: [ old_demo.id ],
          dry_run: false
        ).call
      }.not_to change(AuditLog, :count)

      expect(rerun.converted_company_ids).to eq([])
      expect(rerun.already_converted_company_ids).to eq([ old_demo.id ])
      expect(rerun.changes).to be_empty
      expect(old_demo.reload.updated_at).to eq(company_updated_at)
      expect(demo_link.reload.updated_at).to eq(link_updated_at)
    end

    it "lifts filing/liability/non-employee check DB triggers after conversion while keeping time_tracking_sources refused" do
      described_class.new(organization: organization, actor: admin, company_ids: [ old_demo.id ], dry_run: false).call
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

      # Time tracking sources remain refused in both the model and the database trigger.
      expect(build(:time_tracking_source, company: old_demo)).not_to be_valid
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
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
      other_org = create(:organization)
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

    it "requires an active organization administrator of the same organization" do
      accountant = create(:user, company: live, organization: organization, role: "accountant")
      manager = create(:user, company: live, organization: organization, role: "manager")
      inactive_admin = create(:user, company: live, organization: organization, role: "admin", active: false)
      other_org = create(:organization)
      other_company = create(:company, organization: other_org)
      outsider_admin = create(:user, company: other_company, organization: other_org, role: "admin")

      [ accountant, manager, inactive_admin, outsider_admin, nil ].each do |bad_actor|
        expect {
          described_class.new(organization: organization, actor: bad_actor, company_ids: [ old_demo.id ], dry_run: false).call
        }.to raise_error(described_class::Refused, /organization administrator/)
      end

      expect(old_demo.reload).to be_legacy_demo
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

      # First company committed in its own transaction.
      expect(old_demo.reload[:demo]).to be(true)
      expect(old_demo.payroll_environment).to eq("live")
      expect(demo_link.reload.payroll_environment).to eq("live")

      # Second company rolled back BOTH company and link updates with no audit row.
      expect(second_demo.reload[:demo]).to be(false)
      expect(second_demo.payroll_environment).to eq("migration_rehearsal")
      expect(second_demo.test_workspace_purpose).to eq("demo")
      expect(second_demo.migration_rehearsal_status).to eq("ready")
      expect(second_link.reload.payroll_environment).to eq("migration_rehearsal")
      expect(AuditLog.where(action: described_class::AUDIT_ACTION, record_id: second_demo.id)).to be_empty
    end
  end

  describe "database trigger guardrails" do
    def raw_sql(sql)
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(sql)
      end
    end

    it "refuses direct SQL shape conversion without the transaction-local migration flag and blocks forbidden transitions even with it" do
      # Without SET LOCAL app.allow_demo_shape_migration = 'on', even a valid legacy->flag update is refused.
      expect {
        raw_sql(<<~SQL.squish)
          UPDATE companies
          SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
              migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
              migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL
          WHERE id = #{second_demo.id}
        SQL
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even WITH the flag, converting a real live client to demo is refused.
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL app.allow_demo_shape_migration = 'on'")
          ActiveRecord::Base.connection.execute("UPDATE companies SET demo = TRUE WHERE id = #{live.id}")
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even WITH the flag, converting a legacy demo to a real live client (demo=false) is refused.
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL app.allow_demo_shape_migration = 'on'")
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = FALSE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
                migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL
            WHERE id = #{second_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even WITH the flag, leaving stale rehearsal columns non-null is refused.
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL app.allow_demo_shape_migration = 'on'")
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL
            WHERE id = #{second_demo.id}
          SQL
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /demo companies cannot be converted/)

      # Even WITH the flag, mutating demo_fixture_key during conversion is refused.
      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL app.allow_demo_shape_migration = 'on'")
          ActiveRecord::Base.connection.execute(<<~SQL.squish)
            UPDATE companies
            SET demo = TRUE, payroll_environment = 'live', test_workspace_purpose = NULL,
                migration_rehearsal_status = NULL, migration_rehearsal_created_by_id = NULL,
                migration_rehearsal_created_at = NULL, migration_rehearsal_completed_at = NULL,
                test_workspace_manifest = '{"demo_fixture_key":"tampered-key"}'::jsonb
            WHERE id = #{second_demo.id}
          SQL
        end
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

      # Re-running PostPayStub must NOT create revision 2 or replace the existing posted stub.
      expect {
        EmployeeDocuments::PostPayStub.new(item, now: Time.current).call
      }.not_to change(EmployeeDocument, :count)
      expect(posted_doc.reload.status).to eq("posted")
      expect(posted_doc.revision).to eq(1)
    end
  end

  describe "rake demo:convert_to_flag" do
    let(:task) { Rake::Task["demo:convert_to_flag"] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?("demo:convert_to_flag")
      task.reenable
    end

    def run_task(env_vars)
      keys = %w[ORGANIZATION_ID ACTOR_ID COMPANY_IDS APPLY]
      previous = ENV.to_h.slice(*keys)
      keys.each { |k| ENV.delete(k) }
      env_vars.each { |k, v| ENV[k] = v }
      task.invoke
    ensure
      keys.each { |k| ENV[k] = previous[k] }
    end

    it "runs dry-run by default without printing values, converts on APPLY=true under RLS raise mode, and stays idempotent" do
      allow(RlsContextGuard).to receive(:mode).and_return("raise")
      expect(RlsContextGuard.mode).to eq("raise")

      expect {
        RlsSpecContext.strict { run_task("ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s) }
      }.to output(
        a_string_including(
          "PLAN  company id=#{old_demo.id} company_id=#{old_demo.id} fields=",
          "PLAN  employee_account_link id=#{demo_link.id} company_id=#{old_demo.id} fields=payroll_environment",
          "OK    demo:convert_to_flag mode=dry_run converted=#{old_demo.id} already_converted=none"
        ).and(satisfy { |out| !out.include?("Harbor Finch") && !out.include?("harbor-finch-kitchen") && !/\bready\b/.match?(out) && !out.include?("66-7654321") })
      ).to_stdout

      TenantScope.as_system(reason: "Verify dry run left company unchanged") do
        expect(old_demo.reload).to be_legacy_demo
      end

      task.reenable
      expect {
        RlsSpecContext.strict { run_task("ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "APPLY" => "true") }
      }.to output(/OK    demo:convert_to_flag mode=applied converted=#{old_demo.id} already_converted=none/).to_stdout

      task.reenable
      expect {
        RlsSpecContext.strict { run_task("ACTOR_ID" => admin.id.to_s, "COMPANY_IDS" => old_demo.id.to_s, "APPLY" => "true") }
      }.to output(/OK    demo:convert_to_flag mode=applied converted=none already_converted=#{old_demo.id} changes=0/).to_stdout
    end
  end
end
