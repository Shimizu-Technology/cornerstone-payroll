# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261122020000_add_normalized_invoice_number_index")

RSpec.describe AddNormalizedInvoiceNumberIndex do
  self.use_transactional_tests = false # the index is built CONCURRENTLY

  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }
  let!(:organization) { create(:organization, slug: "number-index-#{SecureRandom.hex(6)}") }
  let!(:profile) { create(:invoice_billing_profile, organization: organization, numbering_style: "continuing", next_invoice_number: 7055) }
  let!(:other_profile) { create(:invoice_billing_profile, organization: organization, name: "Second sender") }
  let(:index_exists) { -> { ActiveRecord::Base.connection.index_name_exists?(:invoices, described_class::INDEX_NAME) } }

  def invoice_numbered(number, billing_profile: profile)
    invoice = create(:invoice, :with_line_item, invoice_billing_profile: billing_profile, company: nil, organization: billing_profile.organization,
                                                invoice_recipient: create(:invoice_recipient, company: nil, organization: billing_profile.organization))
    invoice.update_columns(invoice_number: number)
    invoice
  end

  after do
    migration.migrate(:up) unless index_exists.call
    organization_id = profile.organization_id
    invoice_ids = Invoice.where(organization_id: organization_id).pluck(:id)
    InvoiceLineItem.where(invoice_id: invoice_ids).delete_all
    InvoiceEvent.where(invoice_id: invoice_ids).delete_all
    Invoice.where(id: invoice_ids).delete_all
    InvoiceRecipient.where(organization_id: organization_id).delete_all
    InvoiceBillingProfile.where(organization_id: organization_id).delete_all
    FinanceBook.where(organization_id: organization.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "refuses to build the index over existing duplicates, naming them" do
    migration.migrate(:down)
    first = invoice_numbered("7055")
    second = invoice_numbered("07055")
    expect { migration.migrate(:up) }.to raise_error(/share a number once leading zeros are removed.*billing profile #{profile.id}: 7055 \(invoice #{first.id}\), 07055 \(invoice #{second.id}\)/)
    expect(index_exists.call).to be(false)

    second.update_columns(invoice_number: "07056")
    migration.migrate(:up)
    expect(index_exists.call).to be(true)
  end

  it "allows the same number under different senders and non-numeric numbers" do
    migration.migrate(:down)
    invoice_numbered("7055")
    invoice_numbered("07055", billing_profile: other_profile)
    invoice_numbered("CS-2026-0001")
    invoice_numbered("CS-2026-01")
    migration.migrate(:up)
    expect(index_exists.call).to be(true)
    expect { invoice_numbered("007055") }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
