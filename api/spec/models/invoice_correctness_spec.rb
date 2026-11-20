# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invoice correctness" do
  it "sums rounded lines and preserves matching issued evidence" do
    invoice = create(:invoice)
    2.times { |i| invoice.line_items.build(description: "Fractional service", quantity: "0.5", rate: "0.01", position: i) }
    invoice.save!
    expect(invoice.reload.total_amount).to eq(BigDecimal("0.02"))
    expect(invoice.line_items.sum(:amount)).to eq(invoice.total_amount)
    invoice.issue!(actor: nil)
    expect(invoice.snapshot.fetch("line_items").sum { |line| BigDecimal(line.fetch("amount")) }).to eq(invoice.total_amount)
  end

  it "treats a line with no rate as zero instead of failing" do
    invoice = create(:invoice)
    invoice.line_items.build(description: "Monthly service", quantity: 1, rate: 700, position: 0)
    invoice.line_items.build(description: "Rate to be decided", quantity: 1, rate: nil, position: 1)
    invoice.save!
    expect(invoice.reload.total_amount).to eq(BigDecimal("700"))
    expect(invoice.line_items.order(:position).last.rate).to eq(0)
  end

  it "refreshes old drafts before freezing evidence and preserves old issued totals during voids" do
    invoice = create(:invoice)
    2.times { |i| invoice.line_items.create!(description: "Fractional", quantity: "0.5", rate: "0.01", position: i) }
    invoice.update_columns(total_amount: "0.01")
    invoice.reload.issue!(actor: nil)
    expect(invoice.total_amount).to eq(BigDecimal("0.02"))
    expect(BigDecimal(invoice.snapshot.dig("invoice", "total_amount"))).to eq(invoice.total_amount)
    invoice.update_columns(total_amount: "0.01")
    invoice.reload.archive!(actor: nil)
    invoice.void!(actor: nil, reason: "Preserve original legacy document")
    expect(invoice.reload.total_amount).to eq(BigDecimal("0.01"))
    expect(invoice.balance_due).to eq(0)
  end

  it "rejects unsupported quantity and rate precision" do
    %i[quantity rate].each do |field|
      invoice = build(:invoice, :with_line_item)
      invoice.line_items.first.public_send("#{field}=", "1.005")
      expect(invoice).not_to be_valid
      expect(invoice.line_items.first.errors[field]).to include("cannot have more than two decimal places")
    end
  end

  it "rejects reversed service periods and currencies other than USD" do
    invoice = build(:invoice, :with_line_item, currency: "EUR", service_period_end: Date.new(2026, 4, 1))
    expect(invoice).not_to be_valid
    expect(invoice.errors[:currency]).to be_present
    expect(invoice.errors[:service_period_end]).to be_present
  end

  it "requires an auditable void reason and removes the collectible balance" do
    invoice = create(:invoice, :with_line_item)
    invoice.issue!(actor: nil)
    expect { invoice.void!(actor: nil, reason: " ") }.to raise_error(ActiveRecord::RecordInvalid)
    invoice.void!(actor: nil, reason: "Duplicate November bill")
    expect(invoice.reload.balance_due).to eq(0)
    expect(invoice.events.last.metadata.fetch("reason")).to eq("Duplicate November bill")
  end
end
