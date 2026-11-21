# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceNumberAllocator do
  let(:profile) { create(:invoice_billing_profile, numbering_style: "continuing", next_invoice_number: 7055) }

  def existing_invoice(number, billing_profile: profile)
    organization = billing_profile.organization
    invoice = create(:invoice, :with_line_item, invoice_billing_profile: billing_profile, company: nil, organization: organization,
                                                invoice_recipient: create(:invoice_recipient, company: nil, organization: organization))
    invoice.update_columns(invoice_number: number)
    invoice
  end

  it "zero-pads continuing numbers to the chosen width" do
    profile.update!(invoice_number_width: 5)
    expect(described_class.call(billing_profile: profile, invoice_date: "2026-11-22")).to eq("07055")
    expect(described_class.call(billing_profile: profile, invoice_date: "2026-11-22")).to eq("07056")
    expect(profile.reload.next_invoice_number).to eq(7057)
  end

  it "previews the next number without reserving it, for continuing and yearly senders" do
    profile.update!(invoice_number_width: 5)
    existing_invoice("07055")
    expect(described_class.preview(billing_profile: profile, invoice_date: "2026-11-22")).to eq("07056")
    expect(profile.reload.next_invoice_number).to eq(7055)

    yearly = create(:invoice_billing_profile, organization: profile.organization, numbering_style: "yearly", invoice_prefix: "ST")
    expect(yearly.next_number_preview(Date.new(2026, 11, 22))).to eq("ST-2026-0001")
    described_class.call(billing_profile: yearly, invoice_date: "2026-11-22")
    expect(yearly.next_number_preview(Date.new(2026, 11, 22))).to eq("ST-2026-0002")
    expect(yearly.next_number_preview(Date.new(2027, 1, 2))).to eq("ST-2027-0001")
    expect(InvoiceNumberSequence.where(invoice_billing_profile: yearly).count).to eq(1)
  end

  it "keeps today's unpadded numbers when no width is set, and never cuts a longer number" do
    expect(described_class.call(billing_profile: profile, invoice_date: "2026-11-22")).to eq("7055")
    profile.update!(invoice_number_width: 3)
    expect(described_class.call(billing_profile: profile, invoice_date: "2026-11-22")).to eq("7056")
  end

  it "treats padded and unpadded forms as the same number" do
    existing_invoice("7055")         # issued before padding was turned on
    existing_invoice("07056")        # an imported original with leading zero
    profile.update!(invoice_number_width: 5)
    expect(described_class.call(billing_profile: profile, invoice_date: "2026-11-22")).to eq("07057")

    unpadded = create(:invoice_billing_profile, organization: profile.organization, name: "Unpadded",
                                                numbering_style: "continuing", next_invoice_number: 7052)
    existing_invoice("07052", billing_profile: unpadded)
    expect(described_class.call(billing_profile: unpadded, invoice_date: "2026-11-22")).to eq("7053")
  end

  it "doesn't renumber issued invoices when the width changes" do
    issued = existing_invoice("7055")
    profile.update!(invoice_number_width: 5, next_invoice_number: 7056)
    expect(issued.reload.invoice_number).to eq("7055")
  end

  it "leaves yearly numbering alone" do
    yearly = create(:invoice_billing_profile, organization: profile.organization, name: "Yearly", numbering_style: "yearly",
                                              invoice_prefix: "CS", invoice_number_width: 5)
    expect(described_class.call(billing_profile: yearly, invoice_date: "2026-11-22")).to eq("CS-2026-0001")
  end

  it "rejects a width outside 1 to 12" do
    expect(profile.tap { |record| record.invoice_number_width = 0 }).not_to be_valid
    expect(profile.tap { |record| record.invoice_number_width = 13 }).not_to be_valid
    expect(profile.tap { |record| record.invoice_number_width = nil }).to be_valid
  end
end
