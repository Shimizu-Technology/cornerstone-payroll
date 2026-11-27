# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Track C B4-B6 descriptor-driven gates, submission roles, and MoSa parity" do
  after { PayrollIntake::Registry.reset! }

  def build_synthetic_adapter(key:, tracks_reviewed_hours:, portal_submittable: false, portal_role: nil, accept: %w[.xlsx .csv])
    Class.new do
      define_singleton_method(:descriptor) do
        @descriptor ||= PayrollIntake::Descriptor.new(
          key: key,
          label: "Synthetic #{key.humanize}",
          source_label: "Synthetic #{key.humanize}",
          parser_version: "#{key}:v1",
          adapter_class: self,
          extraction: "deterministic",
          tracks_reviewed_hours: tracks_reviewed_hours,
          idempotency: "files_and_workweek",
          reports_overtime: true,
          tips_default: "paid_in_check",
          overtime_mode: "source_reports",
          workweek_alignment: "warn_if_offset",
          files: portal_role ? [
            {
              role: "universal_workbook",
              label: "Cornerstone workbook",
              hint: "Upload the prefilled Excel or CSV workbook.",
              accept: accept,
              max: 1,
              required_by_default: true,
              portal_role: portal_role,
              portal_label: "Cornerstone payroll workbook",
              portal_hint: "Upload the completed payroll workbook.",
              provides: %w[regular_hours overtime_hours reported_tips]
            }
          ] : [],
          portal: portal_submittable ? { submittable: true, role_map: { portal_role => "universal_workbook" } } : { submittable: false, role_map: {} }
        )
      end
    end
  end

  describe "B4: descriptor-driven tracks_reviewed_hours gates" do
    let(:tracked_adapter) { build_synthetic_adapter(key: "tracked_workbook", tracks_reviewed_hours: true) }
    let(:untracked_adapter) { build_synthetic_adapter(key: "untracked_email", tracks_reviewed_hours: false) }

    before do
      PayrollIntake::Registry.register(tracked_adapter)
      PayrollIntake::Registry.register(untracked_adapter)
    end

    it "exposes tracks_reviewed_hours on built-in descriptors (true for MoSa, false for Spike)" do
      expect(PayrollIntake::Registry.fetch("mosa_revel").tracks_reviewed_hours?).to be(true)
      expect(PayrollIntake::Registry.fetch("spike_email").tracks_reviewed_hours?).to be(false)
      expect(PayrollIntake::Registry.fetch("mosa_revel").serialize.fetch("tracks_reviewed_hours")).to be(true)
      expect(PayrollIntake::Registry.fetch("spike_email").serialize.fetch("tracks_reviewed_hours")).to be(false)
    end

    it "applies all five reviewed-hours gates to any adapter with tracks_reviewed_hours: true and skips them when false" do
      company = create(:company, payroll_intake_source_types: %w[tracked_workbook untracked_email])
      pay_period = create(:pay_period, company: company)
      worker_a = create(:employee, company: company, first_name: "Casey", last_name: "Tracked", pay_rate: 20)
      worker_b = create(:employee, company: company, first_name: "Jordan", last_name: "Untracked", pay_rate: 20)
      owner_a = create(:employee, company: company, first_name: "Pat", last_name: "TrackedOwner",
        employment_type: "salary", salary_type: "variable", pay_rate: 40_000)
      owner_b = create(:employee, company: company, first_name: "Sam", last_name: "UntrackedOwner",
        employment_type: "salary", salary_type: "variable", pay_rate: 40_000)

      rate_a = worker_a.employee_wage_rates.create!(label: "Primary", rate: 20, is_primary: true, active: true)
      rate_b1 = worker_b.employee_wage_rates.create!(label: "Barista", rate: 20, is_primary: true, active: true)
      rate_b2 = worker_b.employee_wage_rates.create!(label: "Roaster", rate: 22, is_primary: false, active: true)

      tracked_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: worker_a,
        hours_worked: 36,
        overtime_hours: 0,
        import_source: "tracked_workbook",
        import_origin: "intake",
        custom_columns_data: {
          "imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" },
          "wage_rate_hours" => [
            { "employee_wage_rate_id" => rate_a.id, "label" => rate_a.label, "rate" => 20.0,
              "regular_hours" => 36.0, "overtime_hours" => 0.0, "holiday_hours" => 0.0, "pto_hours" => 0.0,
              "is_primary" => true, "active" => true }
          ]
        }
      )

      untracked_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: worker_b,
        hours_worked: 36,
        overtime_hours: 0,
        import_source: "untracked_email",
        import_origin: "intake",
        custom_columns_data: {
          "imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" },
          "wage_rate_hours" => [
            { "employee_wage_rate_id" => rate_b1.id, "label" => rate_b1.label, "rate" => 20.0,
              "regular_hours" => 20.0, "overtime_hours" => 0.0, "holiday_hours" => 0.0, "pto_hours" => 0.0,
              "is_primary" => true, "active" => true },
            { "employee_wage_rate_id" => rate_b2.id, "label" => rate_b2.label, "rate" => 22.0,
              "regular_hours" => 16.0, "overtime_hours" => 0.0, "holiday_hours" => 0.0, "pto_hours" => 0.0,
              "is_primary" => false, "active" => true }
          ]
        }
      )

      # Gate 1: PayrollImport::ImportService.overwrite_required?
      expect(tracked_item.tracks_reviewed_hours?).to be(true)
      expect(untracked_item.tracks_reviewed_hours?).to be(false)
      expect(PayrollImport::ImportService.overwrite_required?(tracked_item)).to be(false)
      expect(PayrollImport::ImportService.overwrite_required?(untracked_item)).to be(true)

      # Gate 2: PayrollImport::LivePreviewRowState.hand_edited_hours
      expect(PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => worker_a.id, "employee_name" => worker_a.full_name, "regular_hours" => 41, "overtime_hours" => 0 },
        tracked_item
      )).to include("saved_regular_hours" => "36.0", "source_regular_hours" => "41.0")
      expect(PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => worker_b.id, "employee_name" => worker_b.full_name, "regular_hours" => 41, "overtime_hours" => 0 },
        untracked_item
      )).to be_nil

      # Gate 3: PayrollItem#synchronize_mosa_reviewed_hours!
      tracked_item.update!(hours_worked: 38)
      expect(tracked_item.reload.wage_rate_hours.sole.fetch("regular_hours")).to eq(38.0)
      expect { untracked_item.update!(hours_worked: 38) }.not_to raise_error

      # Gates 4 & 5: PayrollSubmissions::ImportChanges#proposals & #missing_owner_pay
      create(:payroll_item, pay_period: pay_period, employee: owner_a, employment_type: "salary",
        pay_rate: 40_000, salary_override: 1500, import_source: "tracked_workbook", import_origin: "intake")
      create(:payroll_item, pay_period: pay_period, employee: owner_b, employment_type: "salary",
        pay_rate: 40_000, salary_override: 1500, import_source: "untracked_email", import_origin: "intake")

      submission_period = PayrollSubmissionPeriod.create!(
        company: company, pay_period: pay_period, source: "pay_period",
        start_date: pay_period.start_date, end_date: pay_period.end_date
      )
      prior_submission = submission_period.submissions.create!(
        company: company, revision: 1, submitted_at: 1.day.ago,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
        change_rows: [
          { "kind" => "owner_pay", "employee_id" => owner_a.id, "amount" => "1500.00" },
          { "kind" => "owner_pay", "employee_id" => owner_b.id, "amount" => "1500.00" }
        ]
      )
      submission = submission_period.submissions.create!(
        company: company, revision: 2, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
        change_rows: [
          { "kind" => "owner_pay", "employee_id" => owner_a.id, "amount" => "1600.00" },
          { "kind" => "owner_pay", "employee_id" => owner_b.id, "amount" => "1600.00" }
        ]
      )
      proposals = PayrollSubmissions::ImportChanges.new(submission: submission, pay_period: pay_period).proposals
      by_emp = proposals.index_by { |row| row.fetch(:employee_id) }
      expect(by_emp.fetch(owner_a.id).fetch(:overwrite_required)).to be(false)
      expect(by_emp.fetch(owner_b.id).fetch(:overwrite_required)).to be(true)

      # Also test missing_owner_pay (gate 5) when revision 3 drops both owners
      [ owner_a, owner_b ].each do |owner|
        item = pay_period.payroll_items.find_by!(employee: owner)
        item.update!(custom_columns_data: item.custom_columns_data.to_h.merge(
          "client_change_evidence" => { "submission_id" => prior_submission.id, "kind" => "owner_pay" },
          "period_pay_evidence" => { "source_type" => "client_submission" }
        ))
      end
      drop_submission = submission_period.submissions.create!(
        company: company, revision: 3, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
        no_changes: true, change_rows: []
      )
      missing_proposals = PayrollSubmissions::ImportChanges.new(submission: drop_submission, pay_period: pay_period).proposals
      missing_by_emp = missing_proposals.index_by { |row| row.fetch(:employee_id) }
      expect(missing_by_emp.fetch(owner_a.id).fetch(:overwrite_required)).to be(false)
      expect(missing_by_emp.fetch(owner_b.id).fetch(:overwrite_required)).to be(true)
    end
  end

  describe "B5-B6: descriptor-driven portal submission roles and serialization" do
    let(:custom_portal_adapter) do
      build_synthetic_adapter(
        key: "custom_workbook",
        tracks_reviewed_hours: true,
        portal_submittable: true,
        portal_role: "payroll_workbook",
        accept: %w[.xlsx .csv]
      )
    end
    let(:objects) { {} }
    let(:storage) do
      entries = objects
      Object.new.tap do |store|
        store.define_singleton_method(:upload) { |key, data, **| entries[key] = data.respond_to?(:read) ? File.binread(data.path) : data }
        store.define_singleton_method(:download_with_limit) { |key, max_bytes:| entries.fetch(key).byteslice(0, max_bytes) }
        store.define_singleton_method(:delete) { |key| entries.delete(key) }
      end
    end

    before do
      PayrollIntake::Registry.register(custom_portal_adapter)
      allow(R2StorageService).to receive(:new).and_return(storage)
      allow(ClientDocumentScanner).to receive(:adapter).and_return(ClientDocumentScanner::Noop.new)
    end

    it "allows a descriptor-defined portal role end-to-end and serializes its slots for the client UI" do
      company = create(:company, payroll_intake_source_types: [ "custom_workbook" ])
      pay_period = create(:pay_period, company: company,
        start_date: Date.new(2026, 7, 12), end_date: Date.new(2026, 7, 25), pay_date: Date.new(2026, 7, 31))
      client = create(:user, company: company, role: "client")
      CompanyAssignment.create!(user: client, company: company)

      expect(company.portal_payroll_files_enabled?).to be(true)
      expect(PayrollSubmissionDocument.allowed_roles).to include("payroll_workbook")

      catalog = PayrollSubmissions::Catalog.new(company: company, today: pay_period.end_date + 1)
      entry = catalog.resolve("#{pay_period.start_date}_#{pay_period.end_date}")
      detail = PayrollSubmissions::Serializer.new(current_user: client, catalog: catalog).detail(entry)
      expect(detail.fetch(:accepts_files)).to be(true)
      expect(detail.fetch(:allowed_actions)).to include("submit")
      expect(detail.dig(:intake_descriptor, "key")).to eq("custom_workbook")
      expect(detail.dig(:intake_descriptor, "files").sole).to include(
        "portal_role" => "payroll_workbook",
        "portal_label" => "Cornerstone payroll workbook",
        "accept" => %w[.xlsx .csv],
        "required" => true
      )

      csv_upload = portal_upload("period.csv", "employee_id,regular_hours\n1,80\n", "text/csv")
      result = PayrollSubmissions::CreateRevision.new(
        company: company,
        actor: client,
        catalog: catalog,
        entry: entry,
        params: { payroll_workbook: csv_upload, no_changes: true }
      ).call

      expect(result.outcome).to eq(:created)
      doc = result.submission.submission_documents.sole
      expect(doc.role).to eq("payroll_workbook")
      expect(doc.client_document.title).to include("Cornerstone workbook")
    end

    it "enforces role validation at both model and DB levels" do
      company = create(:company, payroll_intake_source_types: [ "custom_workbook" ])
      pay_period = create(:pay_period, company: company)
      client = create(:user, company: company, role: "client")
      period = PayrollSubmissionPeriod.create!(
        company: company, pay_period: pay_period, source: "pay_period",
        start_date: pay_period.start_date, end_date: pay_period.end_date
      )
      submission = period.submissions.create!(
        company: company, revision: 1, submitted_at: Time.current,
        content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32)
      )
      client_doc = ClientDocument.create!(
        company: company, uploaded_by: client, title: "Test", category: "payroll_source",
        file_name: "file.csv", file_key: "client_documents/#{SecureRandom.uuid}.csv",
        content_type: "text/csv", file_size: 10, scan_status: "clean", visible_to_client: true
      )

      unregistered = submission.submission_documents.build(
        company: company, client_document: client_doc, role: "unregistered_role",
        position: 1, sha256: Digest::SHA256.hexdigest("abc"), file_name_snapshot: "file.csv", file_size_snapshot: 10
      )
      expect(unregistered).not_to be_valid
      expect(unregistered.errors[:role]).to be_present

      malformed = submission.submission_documents.build(
        company: company, client_document: client_doc, role: "INVALID ROLE!",
        position: 1, sha256: Digest::SHA256.hexdigest("abc"), file_name_snapshot: "file.csv", file_size_snapshot: 10
      )
      expect { malformed.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /payroll_submission_documents_role/)
    end

    it "keeps non-portal adapters like spike_email blocked from client portal file submission" do
      company = create(:company, payroll_intake_source_types: [ "spike_email" ])
      pay_period = create(:pay_period, company: company)
      client = create(:user, company: company, role: "client")
      catalog = PayrollSubmissions::Catalog.new(company: company, today: pay_period.end_date + 1)
      entry = catalog.resolve("#{pay_period.start_date}_#{pay_period.end_date}")

      expect(company.portal_payroll_files_enabled?).to be(false)
      detail = PayrollSubmissions::Serializer.new(current_user: client, catalog: catalog).detail(entry)
      expect(detail.fetch(:accepts_files)).to be(false)
      expect(detail.fetch(:allowed_actions)).not_to include("submit")
      expect(detail.fetch(:intake_descriptor)).to be_nil
    end

    it "keeps the Revel PDF required in the client portal even when staff required_sources omits revel_hours (M3) and hides descriptor internals from clients (L3)" do
      company = create(
        :company,
        payroll_intake_source_types: [ "mosa_revel" ],
        payroll_intake_settings: { "mosa_revel" => { "required_sources" => [] } }
      )
      pay_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 7, 12),
        end_date: Date.new(2026, 7, 25),
        pay_date: Date.new(2026, 7, 31)
      )
      client = create(:user, company: company, role: "client")
      CompanyAssignment.create!(user: client, company: company)
      catalog = PayrollSubmissions::Catalog.new(company: company, today: pay_period.end_date + 1)
      entry = catalog.resolve("#{pay_period.start_date}_#{pay_period.end_date}")

      detail = PayrollSubmissions::Serializer.new(current_user: client, catalog: catalog).detail(entry)
      revel_slot = detail.dig(:intake_descriptor, "files").find { |slot| slot.fetch("portal_role") == "revel_payroll" }
      expect(revel_slot.fetch("required")).to be(true)
      expect(detail.fetch(:intake_descriptor)).not_to have_key("parser_version")
      expect(detail.fetch(:intake_descriptor)).not_to have_key("idempotency")

      expect do
        PayrollSubmissions::CreateRevision.new(
          company: company,
          actor: client,
          catalog: catalog,
          entry: entry,
          params: { workbook_choice: "none", no_changes: true }
        ).call
      end.to raise_error(PayrollSubmissions::FileSet::Invalid) do |error|
        expect(error.details).to include("revel_payroll" => [ "Attach the Revel payroll PDF" ])
      end
    end

    it "resolves required portal roles mapped solely via portal.role_map and rejects multiple supports_link slots" do
      role_map_only_adapter = Class.new do
        define_singleton_method(:descriptor) do
          @descriptor ||= PayrollIntake::Descriptor.new(
            key: "mapped_only_workbook",
            label: "Mapped Workbook",
            source_label: "Mapped Workbook",
            parser_version: "mapped_only_workbook:v1",
            adapter_class: self,
            extraction: "deterministic",
            tracks_reviewed_hours: true,
            idempotency: "files_and_workweek",
            reports_overtime: true,
            files: [
              {
                role: "universal_workbook",
                label: "Universal workbook",
                accept: %w[.csv],
                max: 1,
                required_by_default: true
              }
            ],
            portal: { submittable: true, role_map: { "mapped_workbook" => "universal_workbook" } }
          )
        end
      end
      PayrollIntake::Registry.register(role_map_only_adapter)

      company = create(:company, payroll_intake_source_types: [ "mapped_only_workbook" ])
      pay_period = create(:pay_period, company: company,
        start_date: Date.new(2026, 7, 12), end_date: Date.new(2026, 7, 25), pay_date: Date.new(2026, 7, 31))
      client = create(:user, company: company, role: "client")
      CompanyAssignment.create!(user: client, company: company)
      catalog = PayrollSubmissions::Catalog.new(company: company, today: pay_period.end_date + 1)
      entry = catalog.resolve("#{pay_period.start_date}_#{pay_period.end_date}")

      expect do
        PayrollSubmissions::CreateRevision.new(
          company: company,
          actor: client,
          catalog: catalog,
          entry: entry,
          params: { no_changes: true }
        ).call
      end.to raise_error(PayrollSubmissions::FileSet::Invalid) do |error|
        expect(error.details).to include("mapped_workbook" => [ "Attach the Universal workbook" ])
      end

      expect do
        PayrollIntake::Descriptor.new(
          key: "two_links",
          label: "Two links",
          parser_version: "two_links:v1",
          adapter_class: Object,
          extraction: "deterministic",
          idempotency: "files_and_workweek",
          files: [
            { role: "wb_a", label: "Workbook A", accept: %w[.xlsx], supports_link: true },
            { role: "wb_b", label: "Workbook B", accept: %w[.xlsx], supports_link: true }
          ]
        )
      end.to raise_error(ArgumentError, /more than one supports_link/)

      expect do
        PayrollIntake::Descriptor.new(
          key: "bad_portal_role",
          label: "Bad Portal Role",
          parser_version: "bad_portal_role:v1",
          adapter_class: Object,
          extraction: "deterministic",
          idempotency: "files_and_workweek",
          files: [
            { role: "wb", label: "Workbook", accept: %w[.xlsx], portal_role: "payroll-workbook" }
          ],
          portal: { submittable: true }
        )
      end.to raise_error(ArgumentError, /invalid portal roles/)
    end

    it "records an imported_hours baseline when PayrollIntake::ApplyService applies a tracks_reviewed_hours adapter" do
      tracked_adapter = build_synthetic_adapter(key: "tracked_intake_baseline", tracks_reviewed_hours: true)
      PayrollIntake::Registry.register(tracked_adapter)
      organization = create(:organization)
      company = create(:company, organization: organization, payroll_intake_source_types: [ "tracked_intake_baseline" ])
      staff = create(:user, organization: organization, company: company, role: "admin")
      pay_period = create(:pay_period, company: company,
        start_date: Date.new(2026, 6, 14), end_date: Date.new(2026, 6, 27), pay_date: Date.new(2026, 7, 3), status: "draft")
      employee = create(:employee, company: company, first_name: "Taylor", last_name: "Tracked", pay_rate: 20.0)
      config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
      create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
      CompanyWorkweek.create!(
        company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
        effective_on: Date.new(2026, 1, 1), source: "operator_confirmed", confirmation_status: "confirmed",
        confirmed_by: staff, confirmed_at: Time.current, notes: "Confirmed"
      )
      session = PayrollIntakeSession.create!(
        company: company, pay_period: pay_period, source_type: "tracked_intake_baseline",
        source_label: "Tracked", import_hash: SecureRandom.hex(32), parser_version: "tracked_intake_baseline:v1",
        package_id: SecureRandom.uuid, package_revision: 1,
        package_schema_version: PayrollIntakeSession::PACKAGE_SCHEMA_VERSION, status: "previewed",
        evidence_snapshot: {
          "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: pay_period, overtime_mode: "source_reports").capture!,
          "intake_settings" => { "overtime_mode" => "source_reports" }
        },
        created_by: staff
      )
      row = session.rows.create!(
        position: 0, source_employee_name: employee.full_name, employee: employee,
        regular_hours: 40, overtime_hours: 2, reported_tips: 0, tips_paid_out: 0, status: "ready"
      )

      applied = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [ { id: row.id, disposition: "included", employee_id: employee.id } ],
        actor: staff
      ).call
      expect(applied[:errors]).to be_empty

      item = pay_period.payroll_items.find_by!(employee: employee)
      expect(item.imported_hours_snapshot).to eq("regular_hours" => "40.0", "overtime_hours" => "2.0")
      expect(item.custom_columns_data["mosa_imported_hours"]).to eq("regular_hours" => "40.0", "overtime_hours" => "2.0")

      item.update!(hours_worked: 38)
      expect(PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => employee.id, "employee_name" => employee.full_name, "regular_hours" => 41, "overtime_hours" => 2 },
        item
      )).to include("saved_regular_hours" => "38.0", "source_regular_hours" => "41.0")
    end

    it "updates both imported_hours and legacy mosa_imported_hours on existing items so hand-edited-hours confirmation still fires" do
      tracked_adapter = build_synthetic_adapter(key: "tracked_intake_legacy_dual", tracks_reviewed_hours: true)
      PayrollIntake::Registry.register(tracked_adapter)
      organization = create(:organization)
      company = create(:company, organization: organization, payroll_intake_source_types: [ "tracked_intake_legacy_dual" ])
      staff = create(:user, organization: organization, company: company, role: "admin")
      pay_period = create(:pay_period, company: company,
        start_date: Date.new(2026, 6, 14), end_date: Date.new(2026, 6, 27), pay_date: Date.new(2026, 7, 3), status: "draft")
      employee = create(:employee, company: company, first_name: "Morgan", last_name: "Legacy", pay_rate: 20.0)
      config = create(:annual_tax_config, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES, tax_year: 2026)
      create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 8600)
      CompanyWorkweek.create!(
        company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
        effective_on: Date.new(2026, 1, 1), source: "operator_confirmed", confirmation_status: "confirmed",
        confirmed_by: staff, confirmed_at: Time.current, notes: "Confirmed"
      )

      # Existing item starts with a legacy mosa_imported_hours baseline of 40h.
      existing = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        hours_worked: 40,
        overtime_hours: 0,
        import_source: "tracked_intake_legacy_dual",
        import_origin: "intake",
        custom_columns_data: {
          "mosa_imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" },
          "imported_hours" => { "regular_hours" => "40.0", "overtime_hours" => "0.0" }
        }
      )

      session = PayrollIntakeSession.create!(
        company: company, pay_period: pay_period, source_type: "tracked_intake_legacy_dual",
        source_label: "Tracked", import_hash: SecureRandom.hex(32), parser_version: "tracked_intake_legacy_dual:v1",
        package_id: SecureRandom.uuid, package_revision: 1,
        package_schema_version: PayrollIntakeSession::PACKAGE_SCHEMA_VERSION, status: "previewed",
        evidence_snapshot: {
          "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: pay_period, overtime_mode: "source_reports").capture!,
          "intake_settings" => { "overtime_mode" => "source_reports" }
        },
        created_by: staff
      )
      row = session.rows.create!(
        position: 0, source_employee_name: employee.full_name, employee: employee,
        regular_hours: 35, overtime_hours: 0, reported_tips: 0, tips_paid_out: 0, status: "ready"
      )

      applied = PayrollIntake::ApplyService.new(
        session: session,
        row_overrides: [ { id: row.id, disposition: "included", employee_id: employee.id } ],
        actor: staff,
        force_overwrite: true
      ).call
      expect(applied[:errors]).to be_empty

      existing.reload
      expect(existing.imported_hours_snapshot).to eq("regular_hours" => "35.0", "overtime_hours" => "0.0")
      expect(existing.custom_columns_data["mosa_imported_hours"]).to eq("regular_hours" => "35.0", "overtime_hours" => "0.0")

      # Staff edits the row back to 40h; a later import of 42h must still trigger hand_edited_hours.
      existing.update!(hours_worked: 40)
      expect(PayrollImport::LivePreviewRowState.hand_edited_hours(
        { "employee_id" => employee.id, "employee_name" => employee.full_name, "regular_hours" => 42, "overtime_hours" => 0 },
        existing
      )).to include("saved_regular_hours" => "40.0", "source_regular_hours" => "42.0")
    end
  end
end
