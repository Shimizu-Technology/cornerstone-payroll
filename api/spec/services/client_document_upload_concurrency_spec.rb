# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe ClientDocumentUploadService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Upload concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:client) { create(:user, company: company, organization: organization, role: "client") }

  after do
    ClientDocument.where(company_id: company.id).delete_all
    User.where(id: client.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "keeps one file set when two first uploads with the same key run at once, and the loser removes its copy" do
    uploaded = Queue.new
    release = Queue.new
    deleted = Queue.new
    allow_any_instance_of(R2StorageService).to receive(:upload).and_wrap_original do |original, key, *rest, **options|
      result = original.call(key, *rest, **options)
      uploaded << key
      release.pop
      result
    end
    allow_any_instance_of(R2StorageService).to receive(:delete).and_wrap_original do |original, key|
      deleted << key
      original.call(key)
    end

    results = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          params = ActionController::Parameters.new(files: [ synthetic_pdf("hours.pdf", marker: "same") ], category: "payroll_source",
            for_message: "true", upload_key: "race-key")
          service = described_class.new(company_id: company.id, current_user: User.find(client.id), params: params)
          # Each caller runs inside its own transaction, as the controller does.
          ClientDocument.transaction { results << [ :ok, service.upload! ] }
        rescue StandardError => error
          results << [ :error, error ]
        end
      end
    end
    begin
      # Both callers have stored bytes before either saves a record.
      keys = Timeout.timeout(15) { Array.new(2) { uploaded.pop } }
      expect(keys.uniq.size).to eq(2)
    ensure
      2.times { release << true }
      threads.each { |thread| thread.join(15) || thread.kill }
    end

    outcomes = Array.new(2) { results.pop(true) }
    expect(outcomes.map(&:first)).to eq(%i[ok ok]), outcomes.inspect
    winner, loser = outcomes.map(&:last).partition { |result| !result.replayed }.map(&:first)
    expect(loser.documents.map(&:id)).to eq(winner.documents.map(&:id))
    saved = ClientDocument.where(company_id: company.id)
    expect(saved.count).to eq(1)
    removed = Array.new(deleted.size) { deleted.pop }
    expect(removed).to eq(keys - [ saved.sole.file_key ])
    expect(R2StorageService.new.exists?(saved.sole.file_key)).to be(true)
  end
end
