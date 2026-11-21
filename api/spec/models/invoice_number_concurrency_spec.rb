# frozen_string_literal: true

require "rails_helper"
require "timeout"

# Two saves of the same number with and without leading zeros, at the same
# moment, on two connections: both pass validation, and the database index
# lets exactly one in. (Adapted from Codex's /tmp/cp_v511_concurrency_spec.rb.)
RSpec.describe "Invoice numbers saved concurrently" do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization, slug: "number-race-#{SecureRandom.hex(6)}") }
  let!(:profile) do
    create(:invoice_billing_profile, organization: organization, numbering_style: "continuing", next_invoice_number: 7055, invoice_number_width: 5)
  end
  let!(:recipient) { create(:invoice_recipient, company: nil, organization: profile.organization) }

  after do
    invoice_ids = Invoice.where(invoice_billing_profile_id: profile.id).pluck(:id)
    InvoiceLineItem.where(invoice_id: invoice_ids).delete_all
    InvoiceEvent.where(invoice_id: invoice_ids).delete_all
    Invoice.where(id: invoice_ids).delete_all
    InvoiceRecipient.where(organization_id: profile.organization_id).delete_all
    InvoiceBillingProfile.where(id: profile.id).delete_all
    FinanceBook.where(organization_id: organization.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "saves one of 7055 and 07055 and rejects the other" do
    arrived = Queue.new
    release = Queue.new
    # Hold each save right after its own validation passed, until both have.
    allow_any_instance_of(Invoice).to receive(:continuing_number_unique_ignoring_zeros).and_wrap_original do |original, *args|
      original.call(*args)
      receiver = original.receiver
      if receiver.invoice_billing_profile_id == profile.id && %w[7055 07055].include?(receiver.invoice_number)
        arrived << receiver.errors.full_messages
        Timeout.timeout(10) { release.pop }
      end
    end

    workers = %w[7055 07055].map do |number|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          invoice = build(:invoice, :with_line_item, company: nil, organization: profile.organization, origin: "imported",
                                                     invoice_billing_profile: InvoiceBillingProfile.find(profile.id),
                                                     invoice_recipient: recipient, invoice_number: number)
          invoice.save!
          :saved
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          e.class
        end
      end
    end
    validations = 2.times.map { Timeout.timeout(10) { arrived.pop } }
    2.times { release << true }
    results = workers.map(&:value)

    expect(validations).to eq([ [], [] ]) # both passed validation: only the index can stop the second
    expect(results).to contain_exactly(:saved, ActiveRecord::RecordNotUnique)
    expect(Invoice.where(invoice_billing_profile_id: profile.id).count).to eq(1)
  end
end
