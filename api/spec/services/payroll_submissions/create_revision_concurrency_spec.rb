# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayrollSubmissions::CreateRevision, :postgres_concurrency do
  include ActiveSupport::Testing::TimeHelpers
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Submission concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
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

  it "gives two simultaneous first sends distinct, consecutive revisions on one period" do
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
            params: { revel_payroll: synthetic_pdf, notes: "sender #{index}" }.with_indifferent_access).call
          results << [ :ok, result.submission.revision ]
        rescue StandardError => error
          results << [ :error, error ]
        end
      end
    end
    Timeout.timeout(15) do
      2.times { arrived.pop }
      2.times { release << true }
      threads.each(&:join)
    end

    outcomes = Array.new(2) { results.pop }
    expect(outcomes.map(&:first)).to eq(%i[ok ok]), outcomes.inspect
    expect(outcomes.map(&:last)).to contain_exactly(1, 2)
    expect(PayrollSubmissionPeriod.where(company_id: company.id).count).to eq(1)
    expect(PayrollSubmission.where(company_id: company.id).order(:revision).pluck(:revision)).to eq([ 1, 2 ])
  end
end
