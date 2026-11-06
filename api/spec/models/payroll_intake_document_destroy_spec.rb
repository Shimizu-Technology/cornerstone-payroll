# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe PayrollIntakeDocument, "stored source deletion", type: :model do
  self.use_transactional_tests = false

  before do
    @directory = Dir.mktmpdir("payroll-document-purge-")
    stub_const("R2StorageService::LOCAL_STORAGE_ROOT", Pathname(@directory))
    @organization = create(:organization, slug: "document-purge-#{SecureRandom.hex(8)}")
    @company = create(:company, organization: @organization)
    @period = create(:pay_period, :calculated, company: @company)
    @session = create(:payroll_intake_session, pay_period: @period, company: @period.company, status: "draft")
    @key = "payroll-intake/synthetic-#{SecureRandom.uuid}.pdf"
    @storage = R2StorageService.new
    allow(@storage).to receive(:configured?).and_return(false)
    @storage.upload(@key, "synthetic personal data")
    @document = @session.documents.create!(document_type: "pdf", storage_reference: @key)
    allow(R2StorageService).to receive(:new).and_return(@storage)
  end

  after do
    @period.reload.destroy! if @period && PayPeriod.exists?(@period.id)
    @company.reload.destroy! if @company&.persisted?
    if @organization&.persisted?
      @organization.finance_books.each(&:destroy!)
      @organization.delete
    end
  ensure
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  it "purges through the storage abstraction only after the deletion commits" do
    PayPeriod.transaction do
      @period.destroy!
      expect(@storage.exists?(@key)).to be(true)
    end
    expect(PayrollIntakeDocument.exists?(@document.id)).to be(false)
    expect(@storage.exists?(@key)).to be(false)
  end

  it "does not purge a stored object when the transaction rolls back" do
    PayPeriod.transaction do
      @period.destroy!
      raise ActiveRecord::Rollback
    end
    expect(PayrollIntakeDocument.exists?(@document.id)).to be(true)
    expect(@storage.exists?(@key)).to be(true)
  end

  it "logs purge failure without failing a committed delete" do
    allow(@storage).to receive(:delete).with(@key).and_raise(R2StorageService::UploadError, "synthetic failure")
    expect(Rails.logger).to receive(:error).with(/Payroll source document #{@document.id} storage purge failed.*synthetic failure/)

    expect { @period.destroy! }.not_to raise_error
    expect(PayrollIntakeDocument.exists?(@document.id)).to be(false)
    expect(PayPeriod.exists?(@period.id)).to be(false)
  end
end
