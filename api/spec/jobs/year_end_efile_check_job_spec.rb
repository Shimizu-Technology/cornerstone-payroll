# frozen_string_literal: true

require "rails_helper"

RSpec.describe YearEndEfileCheckJob do
  include ActiveJob::TestHelper
  let(:company) { create(:company) }
  let(:revision) { YearEnd::InputRevision.for(company.id, 2026)[company.id] }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    clear_enqueued_jobs
  end

  it "deduplicates by company, year and revision, and releases the lease after execution" do
    expect {
      2.times { YearEnd::EfileCheck.enqueue(company.id, 2026, revision) }
    }.to have_enqueued_job(described_class).with(company.id, 2026, revision).exactly(:once)
    expect { YearEnd::EfileCheck.enqueue(company.id, 2026, "new-revision") }
      .to have_enqueued_job(described_class).with(company.id, 2026, "new-revision")
    described_class.perform_now(company.id, 2026, revision)
    expect(Rails.cache.exist?(YearEnd::EfileCheck.pending_key(company.id, 2026, revision))).to be(false)
  end

  it "runs the checklist and stores a current check" do
    create(:payroll_filing_responsibility, :annual, company: company, filing_type: "w2_gu", source_cutoff_date: nil)
    described_class.perform_now(company.id, 2026, revision)
    expect(YearEnd::EfileCheck.read_many([ company.id ], 2026).dig(company.id, :revision)).to eq(revision)
  end

  it "skips superseded inputs" do
    expect(YearEnd::Checklist).not_to receive(:new)
    described_class.perform_now(company.id, 2026, "obsolete")
  end

  it "contains failures without logging private messages and allows another client to run" do
    check = instance_double(YearEnd::Checklist)
    allow(YearEnd::Checklist).to receive(:new).and_return(check)
    allow(check).to receive(:call).and_raise(RuntimeError, "private SSN")
    expect(Rails.logger).to receive(:error).with("Year-end e-file check company_id=#{company.id} year=2026 error_class=RuntimeError")
    expect { described_class.perform_now(company.id, 2026, revision) }.not_to raise_error
    allow(check).to receive(:call).and_return({})
    expect(check).to receive(:call)
    described_class.perform_now(company.id, 2026, revision)
  end

  it "releases the lease when enqueue fails" do
    allow(described_class).to receive(:perform_later).and_raise(RuntimeError, "private SSN")
    allow(Rails.logger).to receive(:error)
    YearEnd::EfileCheck.enqueue(company.id, 2026, revision)
    expect(Rails.cache.exist?(YearEnd::EfileCheck.pending_key(company.id, 2026, revision))).to be(false)
  end
end
