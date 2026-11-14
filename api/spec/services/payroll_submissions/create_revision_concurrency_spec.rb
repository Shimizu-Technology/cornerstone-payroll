# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayrollSubmissions::CreateRevision, :postgres_concurrency do
  include ActiveSupport::Testing::TimeHelpers
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Submission concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:clients) { Array.new(2) { create(:user, company: company, organization: organization, role: "client") } }
  let!(:pay_period) { create(:pay_period, company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 20)) }

  before { travel_to Time.zone.parse("2026-11-17 02:00:00 UTC") }

  after do
    travel_back
    PayrollSubmissionStatusEvent.where(company_id: company.id).delete_all
    PayrollSubmissionDocument.where(company_id: company.id).delete_all
    PayrollSubmission.where(company_id: company.id).delete_all
    PayrollSubmissionPeriod.where(company_id: company.id).delete_all
    PortalNotificationDelivery.where(company_id: company.id).delete_all
    PortalNotificationEvent.where(company_id: company.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    ClientDocument.where(company_id: company.id).delete_all
    PayPeriod.where(company_id: company.id).delete_all
    User.where(id: clients.map(&:id)).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "serializes two simultaneous first sends: one becomes revision 1, the other must reload" do
    arrived = Queue.new
    release = Queue.new
    allow_any_instance_of(PayrollSubmissions::FileSet).to receive(:upload!).and_wrap_original do |original, *args|
      result = original.call(*args)
      arrived << true
      release.pop
      result
    end

    results = Queue.new
    threads = clients.each_with_index.map do |client, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          catalog = PayrollSubmissions::Catalog.new(company: Company.find(company.id))
          entry = catalog.resolve("2026-11-02_2026-11-15")
          result = described_class.new(company: Company.find(company.id), actor: User.find(client.id), entry: entry, catalog: catalog,
            params: { workbook_choice: "none", revel_payroll: synthetic_pdf, notes: "sender #{index}" }.with_indifferent_access).call
          results << [ :ok, result.submission.revision ]
        rescue StandardError => error
          results << [ :error, error ]
        end
      end
    end
    begin
      Timeout.timeout(15) { 2.times { arrived.pop } }
    ensure
      # Always release both workers, even after a timeout or a failed worker,
      # so no thread keeps a database connection into later examples.
      2.times { release << true }
      threads.each { |thread| thread.join(10) || thread.kill }
    end

    outcomes = Array.new(2) { results.pop(true) }
    expect(outcomes.map(&:first)).to contain_exactly(:ok, :error), outcomes.inspect
    expect(outcomes.find { |kind, _| kind == :ok }.last).to eq(1)
    expect(outcomes.find { |kind, _| kind == :error }.last).to be_a(described_class::Conflict)
    expect(PayrollSubmissionPeriod.where(company_id: company.id).count).to eq(1)
    expect(PayrollSubmission.where(company_id: company.id).pluck(:revision)).to eq([ 1 ])
    expect(ClientDocument.where(company_id: company.id).count).to eq(1)
  end
end
