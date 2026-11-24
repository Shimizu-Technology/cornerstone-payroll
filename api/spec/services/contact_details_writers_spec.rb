# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Contact details write path guards (bootstrap, promotion, change requests)" do
  describe "QuickBooks bootstrap" do
    before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

    let!(:company) { create(:company) }
    let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
    let!(:batch) do
      QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    end

    after do
      cleanup_quickbooks_history_uploads
      FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
    end

    it "routes bootstrap contacts through the validator with contact_source='import', blanks invalid/placeholder emails without failing, and reports blanked counts" do
      EmployeePlaceholderEmail.create!(organization: company.organization, email: "shared-mosa@example.com")

      workers = batch.historical_workers.order(:id).to_a
      # Inject a marked placeholder email on worker 1, an invalid email on worker 2, and a valid email + Guam phone on worker 3.
      [
        [ workers[0], "shared-mosa@example.com", "555-0191" ],
        [ workers[1], "not-a-valid-email", "abc-bad" ],
        [ workers[2], "Valid.Worker@Example.COM", "555-0192" ]
      ].each do |worker, email, phone|
        snapshot = worker.private_snapshot_data.deep_dup
        snapshot["_employee_directory"]["Email"] = email
        snapshot["_employee_directory"]["Phone"] = phone
        worker.update!(private_snapshot: JSON.generate(snapshot))
      end

      bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
      expect(bootstrap).to be_ready_to_apply
      expect(bootstrap.preview_summary).to include(
        "blanked_contact_email_count" => 2,
        "blanked_contact_phone_count" => 1
      )

      QuickbooksHistory::ClientBootstrapApplyService.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
      ).call

      expect(bootstrap.reload).to be_applied
      employees = workers.map { |w| w.reload.employee }
      expect(employees[0].email).to be_nil
      expect(employees[0].phone).to eq("+16715550191")
      expect(employees[0].contact_source).to eq("import")
      expect(employees[0].email_verified_at).to be_nil

      expect(employees[1].email).to be_nil
      expect(employees[1].phone).to be_nil

      expect(employees[2].email).to eq("valid.worker@example.com")
      expect(employees[2].phone).to eq("+16715550192")
      expect(employees[2].contact_source).to eq("import")

      audit = AuditLog.where(action: "historical_imports#apply_client_bootstrap", company_id: company.id).newest_first.first
      expect(audit.metadata).to include(
        "blanked_contact_email_count" => 2,
        "blanked_contact_phone_count" => 1
      )
    end
  end

  describe "Migration promotion SetupSynchronizer" do
    let(:organization) { create(:organization) }
    let(:target_company) { create(:company, organization: organization) }
    let(:source_batch) do
      create(:historical_import_batch, company: target_company, status: "locked")
    end
    let(:rehearsal) do
      create(
        :company,
        organization: organization,
        payroll_environment: "migration_rehearsal",
        test_workspace_purpose: "migration_rehearsal",
        migration_source_company: target_company,
        migration_source_batch: source_batch,
        migration_rehearsal_status: "ready"
      )
    end
    let(:actor) { create(:user, company: target_company, organization: organization, role: "admin") }
    let!(:target_department) { create(:department, company: target_company) }
    let!(:rehearsal_department) { create(:department, company: rehearsal) }
    let!(:live_employee) do
      create(
        :employee,
        company: target_company,
        department: target_department,
        first_name: "Ana",
        last_name: "Live",
        email: "ana.live@example.com",
        phone: "+16715550111",
        address_line1: "100 Live Rd",
        city: "Hagatna",
        state: "GU",
        zip: "96910",
        contact_source: "employee",
        email_verified_at: 3.days.ago,
        phone_confirmed_by_employee_at: 3.days.ago
      )
    end
    let!(:rehearsal_employee) do
      create(
        :employee,
        company: rehearsal,
        department: rehearsal_department,
        test_workspace_source_employee: live_employee,
        first_name: "Ana",
        last_name: "Live",
        email: "rehearsal.changed@example.com",
        phone: "+16715550222",
        address_line1: "200 Rehearsal St",
        email_verified_at: 1.hour.ago,
        phone_confirmed_by_employee_at: 1.hour.ago
      )
    end
    let!(:new_rehearsal_employee) do
      create(
        :employee,
        company: rehearsal,
        department: rehearsal_department,
        first_name: "Brand",
        last_name: "New",
        email: "noemail@example.com",
        phone: "555-0333",
        email_verified_at: 1.hour.ago,
        phone_confirmed_by_employee_at: 1.hour.ago
      )
    end

    it "preserves live contact details unless explicitly reviewed for replacement and never copies verification timestamps from rehearsal" do
      mapping = MigrationPromotion::EmployeeMapper::Result.new(
        map: { rehearsal_employee.id => live_employee },
        new_employees: [ new_rehearsal_employee ],
        blockers: []
      )

      maps = MigrationPromotion::SetupSynchronizer.new(
        rehearsal: rehearsal,
        target_company: target_company,
        actor: actor,
        mapping: mapping
      ).call

      live_employee.reload
      expect(live_employee.email).to eq("ana.live@example.com")
      expect(live_employee.phone).to eq("+16715550111")
      expect(live_employee.address_line1).to eq("100 Live Rd")
      expect(live_employee.email_verified_at).to be_present
      expect(live_employee.phone_confirmed_by_employee_at).to be_present

      created_new = maps.fetch(:employees).fetch(new_rehearsal_employee.id).reload
      expect(created_new.email).to be_nil # placeholder blanked on new employee
      expect(created_new.phone).to eq("+16715550333")
      expect(created_new.contact_source).to eq("import")
      expect(created_new.email_verified_at).to be_nil
      expect(created_new.phone_confirmed_by_employee_at).to be_nil
    end

    it "replaces live contact details when explicitly reviewed and clears verification timestamps instead of copying rehearsal ones" do
      mapping = MigrationPromotion::EmployeeMapper::Result.new(
        map: { rehearsal_employee.id => live_employee },
        new_employees: [ new_rehearsal_employee ],
        blockers: []
      )

      MigrationPromotion::SetupSynchronizer.new(
        rehearsal: rehearsal,
        target_company: target_company,
        actor: actor,
        mapping: mapping,
        replace_contact_employee_ids: [ live_employee.id ]
      ).call

      live_employee.reload
      expect(live_employee.email).to eq("rehearsal.changed@example.com")
      expect(live_employee.phone).to eq("+16715550222")
      expect(live_employee.address_line1).to eq("200 Rehearsal St")
      expect(live_employee.contact_source).to eq("staff")
      expect(live_employee.email_verified_at).to be_nil
      expect(live_employee.phone_confirmed_by_employee_at).to be_nil
    end
  end

  describe "EmployeeChangeRequest#apply!" do
    let(:company) { create(:company) }
    let(:client_user) { create(:user, company: company, organization: company.organization, role: "client") }
    let(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
    let(:employee) { create(:employee, company: company, email: "old@example.com") }

    it "routes email/phone changes in legacy change requests through EmployeeContactValidator" do
      bad_request = EmployeeChangeRequest.create!(
        company: company,
        employee: employee,
        requested_by: client_user,
        request_kind: "update",
        proposed_changes: { "email" => "noemail@example.com" },
        original_values: { "email" => "old@example.com" }
      )

      expect { bad_request.apply!(actor: admin_user) }.to raise_error(ActiveRecord::RecordInvalid, /placeholder/i)
      expect(employee.reload.email).to eq("old@example.com")
    end
  end
end
