# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Concurrent continuing invoice issue", :postgres_concurrency do
  self.use_transactional_tests = false

  it "issues eight unique sequential numbers while skipping a manually held number" do
    profile = create(:invoice_billing_profile, numbering_style: "continuing", next_invoice_number: 7055)
    recipient = create(:invoice_recipient, organization: profile.organization, company: nil, finance_book: profile.finance_book)
    held = create(:invoice, :with_line_item, organization: profile.organization, company: nil,
      invoice_billing_profile: profile, invoice_recipient: recipient, invoice_number: "7058")
    drafts = 8.times.map do
      create(:invoice, :with_line_item, organization: profile.organization, company: nil,
        invoice_billing_profile: profile, invoice_recipient: recipient, invoice_number: nil)
    end
    ready = Queue.new
    release = Queue.new
    threads = drafts.map do |draft|
      Thread.new do
        ready << true
        release.pop
        ActiveRecord::Base.connection_pool.with_connection { Invoice.find(draft.id).issue!(actor: nil) }
      end
    end
    Timeout.timeout(10) { 8.times { ready.pop } }
    8.times { release << true }
    threads.each { |thread| Timeout.timeout(30) { thread.value } }
    expect(drafts.map { |draft| draft.reload.invoice_number.to_i }.sort).to eq([ 7055, 7056, 7057, 7059, 7060, 7061, 7062, 7063 ])
    expect(profile.reload.next_invoice_number).to eq(7064)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    ids = Array(drafts).map(&:id) + [ held&.id ].compact
    InvoiceEvent.where(invoice_id: ids).delete_all
    InvoiceLineItem.where(invoice_id: ids).delete_all
    Invoice.where(id: ids).delete_all
    InvoiceRecipient.where(id: recipient&.id).delete_all
    InvoiceNumberSequence.where(invoice_billing_profile_id: profile&.id).delete_all
    InvoiceBillingProfile.where(id: profile&.id).delete_all
    FinanceBook.where(organization_id: profile&.organization_id).delete_all
    Organization.where(id: profile&.organization_id).delete_all
  end
end
