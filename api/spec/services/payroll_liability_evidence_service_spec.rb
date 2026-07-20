# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe PayrollLiabilityEvidenceService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company:, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company:) }
  let(:posting) do
    PayrollLiabilityPosting.create!(
      company:,
      pay_period:,
      posting_type: "commit",
      liability_date: pay_period.pay_date,
      posted_at: Time.current,
      posted_by: actor,
      idempotency_key: "evidence-posting-#{pay_period.id}"
    )
  end
  let!(:entry) do
    PayrollLiabilityEntry.create!(
      payroll_liability_posting: posting,
      company:,
      component_key: "guam_income_tax_withheld",
      category: "guam_income_tax_withheld",
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      amount: 25
    )
  end
  let(:payment) do
    PayrollLiabilitySettlementService.record!(
      pay_period:,
      actor:,
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 25,
      payment_date: "2026-07-20",
      payment_method: "ach"
    )
  end
  let(:storage) { instance_double(R2StorageService) }

  it "preserves allowed evidence with a digest and verifies it on download" do
    bytes = "%PDF-1.4\nliability proof\n%%EOF\n".b
    uploaded = uploaded_file(bytes, "receipt.pdf", "application/pdf")
    stored = {}
    allow(storage).to receive(:upload) do |key, io, content_type:|
      stored[key] = io.read
      expect(content_type).to eq("application/pdf")
    end
    allow(storage).to receive(:download_with_limit) { |key, max_bytes:| stored.fetch(key) }

    evidence = described_class.new(payment:, actor:, storage:).attach!(file: uploaded)

    expect(evidence).to have_attributes(
      filename: "receipt.pdf",
      content_type: "application/pdf",
      byte_size: bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(bytes)
    )
    expect(described_class.new(payment:, actor:, storage:).download!(evidence)).to eq(bytes)
  ensure
    uploaded&.tempfile&.close!
  end

  it "rejects unsupported file content before uploading" do
    uploaded = uploaded_file("plain text", "receipt.txt", "text/plain")
    expect(storage).not_to receive(:upload)

    expect {
      described_class.new(payment:, actor:, storage:).attach!(file: uploaded)
    }.to raise_error(ArgumentError, /PDF, JPEG, PNG, or WebP/)
  ensure
    uploaded&.tempfile&.close!
  end

  it "rejects downloaded evidence that no longer matches its immutable digest" do
    bytes = "%PDF-1.4\nproof\n%%EOF\n".b
    uploaded = uploaded_file(bytes, "receipt.pdf", "application/pdf")
    allow(storage).to receive(:upload)
    evidence = described_class.new(payment:, actor:, storage:).attach!(file: uploaded)
    allow(storage).to receive(:download_with_limit).and_return("tampered")

    expect {
      described_class.new(payment:, actor:, storage:).download!(evidence)
    }.to raise_error(R2StorageService::DownloadError, /integrity/)
  ensure
    uploaded&.tempfile&.close!
  end

  def uploaded_file(bytes, filename, content_type)
    tempfile = Tempfile.new([ "liability-evidence", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile:, filename:, type: content_type)
  end
end
