# frozen_string_literal: true

require "rails_helper"

RSpec.describe Invoice, type: :model do
  it "calculates total amount from line items" do
    invoice = build(:invoice, :with_line_item)
    invoice.line_items.build(description: "Bookkeeping", quantity: 1.5, rate: 80, position: 1)

    expect(invoice).to be_valid
    expect(invoice.total_amount).to eq(420)
  end

  it "requires line items when issued" do
    invoice = build(:invoice, status: "open")

    expect(invoice).not_to be_valid
    expect(invoice.errors[:line_items]).to include("must include at least one line item")
  end

  it "assigns an invoice number when one is not supplied" do
    recipient = create(:invoice_recipient, invoice_prefix: "CS")
    billing_profile = create(:invoice_billing_profile, organization: recipient.organization, invoice_prefix: "ST")
    invoice = create(
      :invoice,
      :with_line_item,
      company: recipient.company,
      invoice_recipient: recipient,
      invoice_billing_profile: billing_profile,
      invoice_number: nil
    )

    expect(invoice.invoice_number).to match(/\AST-\d{4}-\d{4}\z/)
  end

  it "captures a billing and recipient snapshot when generated" do
    billing_profile = create(:invoice_billing_profile, name: "Shimizu Technology", invoice_prefix: "ST")
    recipient = create(:invoice_recipient, company: billing_profile.organization.companies.first || create(:company, organization: billing_profile.organization), name: "Pacific Client")
    invoice = create(:invoice, :with_line_item, company: recipient.company, organization: billing_profile.organization, invoice_billing_profile: billing_profile, invoice_recipient: recipient)

    invoice.mark_generated!(actor: nil)

    expect(invoice.snapshot.dig("billing_profile", "name")).to eq("Shimizu Technology")
    expect(invoice.snapshot.dig("recipient", "name")).to eq("Pacific Client")
    expect(invoice.snapshot.fetch("line_items").first.fetch("description")).to eq("Payroll services")
  end

  it "requires delivery and payment evidence instead of manual workflow status changes" do
    invoice = create(:invoice, :with_line_item, :generated)
    actor = create(:user, company: invoice.company)

    expect {
      invoice.update_status!("sent", actor: actor)
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(invoice.reload.status).to eq("open")
  end

  it "rolls back lifecycle state when its audit event cannot be recorded" do
    actor = create(:user)
    invalid_event = InvoiceEvent.new
    invalid_event.errors.add(:base, "Forced lifecycle audit failure")
    transitions = [
      {
        invoice: create(:invoice, :with_line_item, :generated, organization: actor.organization, company: actor.company),
        event_type: "voided",
        action: ->(invoice) { invoice.void!(actor: actor, reason: "Duplicate") },
        expected: { status: "open", voided_at: nil }
      },
      {
        invoice: create(:invoice, :with_line_item, :generated, organization: actor.organization, company: actor.company),
        event_type: "marked_uncollectible",
        action: ->(invoice) { invoice.mark_uncollectible!(actor: actor, reason: "Collection exhausted") },
        expected: { status: "open" }
      },
      {
        invoice: create(:invoice, :with_line_item, organization: actor.organization, company: actor.company),
        event_type: "archived",
        action: ->(invoice) { invoice.archive!(actor: actor) },
        expected: { archived: false, archived_at: nil }
      },
      {
        invoice: create(:invoice, :with_line_item, organization: actor.organization, company: actor.company, archived: true, archived_at: 1.day.ago),
        event_type: "restored",
        action: ->(invoice) { invoice.restore!(actor: actor) },
        expected: { archived: true }
      }
    ]

    transitions.each do |transition|
      invoice = transition.fetch(:invoice)
      allow(InvoiceEvent).to receive(:record!).and_call_original
      allow(InvoiceEvent).to receive(:record!)
        .with(hash_including(invoice: have_attributes(id: invoice.id), event_type: transition.fetch(:event_type)))
        .and_raise(ActiveRecord::RecordInvalid.new(invalid_event))

      expect { transition.fetch(:action).call(invoice) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(invoice.reload).to have_attributes(transition.fetch(:expected))
      expect(invoice.events.where(event_type: transition.fetch(:event_type))).to be_empty
    end
  end
end
