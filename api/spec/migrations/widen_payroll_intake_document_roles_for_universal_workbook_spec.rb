# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127220000_widen_payroll_intake_document_roles_for_universal_workbook")

RSpec.describe WidenPayrollIntakeDocumentRolesForUniversalWorkbook, type: :migration do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }

  before do
    connection.clear_cache!
  end

  after do
    connection.clear_cache!
    unless constraint_definition.include?("^[a-z][a-z0-9_]{0,63}$") && workbook_index_metadata&.fetch("indisvalid") == true
      migration.up
      connection.clear_cache!
    end
  end

  def constraint_definition
    connection.check_constraints(:payroll_intake_documents)
      .find { |check| check.name == described_class::CONSTRAINT_NAME }
      &.expression.to_s
  end

  def workbook_index_metadata
    row = connection.select_one(<<~SQL.squish)
      SELECT i.indisvalid, i.indisunique, pg_get_indexdef(i.indexrelid) AS indexdef
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relname = #{connection.quote(described_class::WORKBOOK_INDEX_NAME)}
    SQL
    return nil if row.nil?

    row.merge(
      "indisvalid" => ActiveModel::Type::Boolean.new.cast(row["indisvalid"]),
      "indisunique" => ActiveModel::Type::Boolean.new.cast(row["indisunique"])
    )
  end

  def create_submission_fixture!
    organization = create(:organization, slug: "mig-wb-#{SecureRandom.hex(4)}")
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
    {
      organization: organization,
      company: company,
      pay_period: pay_period,
      user: user,
      period: period,
      submission: submission,
      client_docs: [],
      submission_docs: []
    }
  end

  def attach_submission_doc!(fixture, role:, position:)
    client_doc = ClientDocument.create!(
      company: fixture[:company],
      uploaded_by: fixture[:user],
      title: "Migration workbook #{position}",
      category: "payroll_source",
      file_name: "workbook-#{position}.csv",
      file_key: "client_documents/#{SecureRandom.uuid}.csv",
      content_type: "text/csv",
      file_size: 16,
      scan_status: "clean",
      visible_to_client: true
    )
    fixture[:client_docs] << client_doc
    doc = fixture[:submission].submission_documents.build(
      company: fixture[:company],
      client_document: client_doc,
      role: role,
      position: position,
      sha256: Digest::SHA256.hexdigest("mig-#{position}-#{SecureRandom.hex(4)}"),
      file_name_snapshot: "workbook-#{position}.csv",
      file_size_snapshot: 16
    )
    doc.save!(validate: false)
    fixture[:submission_docs] << doc
    doc
  end

  def cleanup_fixture!(fixture)
    fixture[:submission_docs].each(&:delete)
    fixture[:client_docs].each(&:delete)
    fixture[:submission].delete
    fixture[:period].delete
    fixture[:user].delete
    fixture[:pay_period].delete
    fixture[:company].delete
    fixture[:organization].delete
  end

  it "drops an INVALID leftover concurrent index and rebuilds a valid unique partial index on retry" do
    fixture = create_submission_fixture!

    begin
      migration.down
      expect(workbook_index_metadata).to be_nil

      # Simulate a failed CREATE UNIQUE INDEX CONCURRENTLY by inserting two
      # payroll_workbook rows on the same submission; PostgreSQL aborts the
      # concurrent build and leaves an INVALID index with the target name.
      attach_submission_doc!(fixture, role: "payroll_workbook", position: 1)
      duplicate_doc = attach_submission_doc!(fixture, role: "payroll_workbook", position: 2)

      expect {
        connection.execute(<<~SQL.squish)
          CREATE UNIQUE INDEX CONCURRENTLY #{connection.quote_table_name(described_class::WORKBOOK_INDEX_NAME)}
          ON payroll_submission_documents (payroll_submission_id)
          WHERE (role = 'payroll_workbook')
        SQL
      }.to raise_error(ActiveRecord::RecordNotUnique)

      invalid_meta = workbook_index_metadata
      expect(invalid_meta).not_to be_nil
      expect(invalid_meta["indisvalid"]).to be(false)

      # Remove the duplicate row and retry migration.up
      duplicate_doc.delete
      fixture[:submission_docs].delete(duplicate_doc)

      expect { migration.up }.not_to raise_error

      rebuilt = workbook_index_metadata
      expect(rebuilt).not_to be_nil
      expect(rebuilt["indisvalid"]).to be(true)
      expect(rebuilt["indisunique"]).to be(true)
      expect(rebuilt["indexdef"]).to include("UNIQUE INDEX #{described_class::WORKBOOK_INDEX_NAME}")
      expect(rebuilt["indexdef"]).to include("(payroll_submission_id)")
      expect(rebuilt["indexdef"]).to include("WHERE ((role)::text = 'payroll_workbook'::text)")

      # Confirm the rebuilt index actively enforces uniqueness on payroll_workbook
      expect {
        attach_submission_doc!(fixture, role: "payroll_workbook", position: 3)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    ensure
      cleanup_fixture!(fixture)
    end
  end

  it "is idempotent when re-run with a valid index already in place" do
    expect { migration.up }.not_to raise_error
    meta = workbook_index_metadata
    expect(meta["indisvalid"]).to be(true)
    expect(meta["indisunique"]).to be(true)
  end
end
