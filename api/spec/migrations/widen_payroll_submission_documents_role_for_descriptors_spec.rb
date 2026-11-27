# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127190000_widen_payroll_submission_documents_role_for_descriptors")

RSpec.describe WidenPayrollSubmissionDocumentsRoleForDescriptors, type: :migration do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    # Always leave the test DB with the expanded canonical constraint in place.
    migration.up unless constraint_definition.include?("^[a-z][a-z0-9_]{0,63}$")
  end

  def constraint_names
    connection.check_constraints(:payroll_submission_documents).map(&:name)
  end

  def constraint_definition
    connection.check_constraints(:payroll_submission_documents)
      .find { |check| check.name == described_class::CONSTRAINT_NAME }
      &.expression.to_s
  end

  def insert_submission_document!(role:)
    organization = create(:organization, slug: "mig-test-#{SecureRandom.hex(4)}")
    company = create(:company, organization: organization)
    pay_period = create(:pay_period, company: company)
    user = create(:user, organization: organization, company: company, role: "client")
    period = PayrollSubmissionPeriod.create!(
      company: company,
      pay_period: pay_period,
      source: "pay_period",
      start_date: pay_period.start_date,
      end_date: pay_period.end_date
    )
    submission = period.submissions.create!(
      company: company,
      revision: 1,
      submitted_at: Time.current,
      content_fingerprint: SecureRandom.hex(32),
      request_fingerprint: SecureRandom.hex(32)
    )
    client_doc = ClientDocument.create!(
      company: company,
      uploaded_by: user,
      title: "Migration test",
      category: "payroll_source",
      file_name: "file.csv",
      file_key: "client_documents/#{SecureRandom.uuid}.csv",
      content_type: "text/csv",
      file_size: 10,
      scan_status: "clean",
      visible_to_client: true
    )
    doc = submission.submission_documents.build(
      company: company,
      client_document: client_doc,
      role: role,
      position: 1,
      sha256: Digest::SHA256.hexdigest("migration-#{SecureRandom.hex(4)}"),
      file_name_snapshot: "file.csv",
      file_size_snapshot: 10
    )
    doc.save!(validate: false)
    [ doc, submission, period, client_doc, user, pay_period, company, organization ]
  end

  def cleanup_records!(doc, submission, period, client_doc, user, pay_period, company, organization)
    doc.delete
    submission.delete
    period.delete
    client_doc.delete
    user.delete
    pay_period.delete
    company.delete
    organization.delete
  end

  it "drops the temporary constraint if rollback validation fails when a descriptor-role row exists" do
    records = insert_submission_document!(role: "payroll_workbook")
    begin
      expect { migration.down }.to raise_error(ActiveRecord::StatementInvalid)
      expect(constraint_names).not_to include(described_class::ORIGINAL_TMP)
      expect(constraint_names).to include(described_class::CONSTRAINT_NAME)
      expect(constraint_definition).to include("^[a-z][a-z0-9_]{0,63}$")
    ensure
      cleanup_records!(*records)
    end
  end

  it "restores the original allowlist cleanly on rollback when only legacy roles exist" do
    records = insert_submission_document!(role: "revel_payroll")
    begin
      expect { migration.down }.not_to raise_error
      expect(constraint_names).not_to include(described_class::ORIGINAL_TMP)
      expect(constraint_names).to include(described_class::CONSTRAINT_NAME)
      expect(constraint_definition).to include("revel_payroll")
      expect(constraint_definition).not_to include("^[a-z][a-z0-9_]{0,63}$")

      expect { migration.up }.not_to raise_error
      expect(constraint_definition).to include("^[a-z][a-z0-9_]{0,63}$")
    ensure
      cleanup_records!(*records)
    end
  end
end
