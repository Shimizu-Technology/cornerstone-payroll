# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayrollSubmissions::ImportBridge, :postgres_concurrency do
  self.use_transactional_tests = false
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:run) { create(:pay_period, company: company) }
  let!(:period) { PayrollSubmissionPeriod.create!(company: company, pay_period: run, source: "pay_period", start_date: run.start_date, end_date: run.end_date) }
  let!(:source) { period.submissions.create!(company: company, revision: 1, submitted_by: actor, submitted_at: Time.current, content_fingerprint: "source", request_fingerprint: "source") }

  before do
    bytes = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } ], period_start: run.start_date, period_end: run.end_date))
    document = ClientDocument.create!(company: company, uploaded_by: actor, title: "Synthetic source", category: "payroll_source",
      file_name: "source.pdf", file_key: "bridge-concurrency/#{SecureRandom.uuid}", file_size: bytes.bytesize, content_type: "application/pdf", scan_status: "clean", visible_to_client: true)
    source.submission_documents.create!(company: company, client_document: document, role: "revel_payroll", position: 0,
      sha256: Digest::SHA256.hexdigest(bytes), file_name_snapshot: "source.pdf", file_size_snapshot: bytes.bytesize)
    storage = Object.new
    storage.define_singleton_method(:download_with_limit) { |*, **| bytes }
    allow(R2StorageService).to receive(:new).and_return(storage)
    # This spec tests the bridge's database lock boundary, not parsing (covered
    # by request specs using the real #433 parser). Avoid external blob writes.
    fake = instance_double(PayrollIntake::PreviewService, call: { session: double(documents: []), duplicate: false })
    allow(PayrollIntake::PreviewService).to receive(:new).and_return(fake)
  end

  after do
    PayrollSubmissionStatusEvent.where(company_id: company.id).delete_all
    PayrollSubmissionDocument.where(company_id: company.id).delete_all
    PayrollSubmission.where(company_id: company.id).delete_all
    PayrollSubmissionPeriod.where(company_id: company.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    ClientDocument.where(company_id: company.id).delete_all
    PayPeriod.where(company_id: company.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: company.organization_id).delete_all
  end

  it "holds the same company/run locks while a correction waits, then leaves the correction pending" do
    entered = Queue.new
    release = Queue.new
    correcting = Queue.new
    corrected = Queue.new
    errors = Queue.new
    bridge = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(pay_period: PayPeriod.find(run.id), actor: actor, submission_id: source.id).call do |_result, _selected, current, _reason, _files|
          entered << current
          release.pop
        end
      end
    rescue StandardError => error
      errors << error
    end
    Timeout.timeout(5) { entered.pop }
    correction = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        correcting << true
        Company.find(company.id).with_lock do
          PayPeriod.find(run.id).lock!
          portal = PayrollSubmissionPeriod.lock.find(period.id)
          portal.submissions.create!(company: company, revision: 2, submitted_by: actor, submitted_at: Time.current,
            content_fingerprint: "correction", request_fingerprint: "correction")
          corrected << true
        end
      end
    rescue StandardError => error
      errors << error
    end
    Timeout.timeout(5) { correcting.pop }
    # Prove the competing connection is actually waiting on a PostgreSQL lock.
    Timeout.timeout(5) do
      loop do
        waiting = ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'")
        break if waiting.to_i.positive?
        Thread.pass
      end
    end
    expect(corrected).to be_empty
    release << true
    [ bridge, correction ].each { |thread| expect(thread.join(5)).to be_present }
    raise errors.pop unless errors.empty?
    expect(period.reload.current_submission.revision).to eq(2)
    expect(run.reload.pending_portal_submission?).to be(true)
  ensure
    release << true if release
    [ bridge, correction ].compact.each { |thread| thread.join(5) }
  end

  it "rejects a source when commit wins the financial lock first" do
    run.update_columns(status: "committed", committed_at: Time.current)
    expect do
      described_class.new(pay_period: run.reload, actor: actor, submission_id: source.id).call { raise "must not parse committed payroll" }
    end.to raise_error(ArgumentError, /non-editable/)
  end
end
