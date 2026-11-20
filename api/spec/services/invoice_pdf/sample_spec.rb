# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoicePdf::Sample do
  let(:today) { Date.new(2026, 11, 2) }

  def sample_for(terms)
    described_class.snapshot(build(:invoice_billing_profile, default_payment_terms: terms), today: today).fetch("invoice")
  end

  it "derives the due date from the terms it prints, like a real draft" do
    expect(sample_for("Net 30")).to include("payment_terms" => "Net 30", "due_date" => "2026-12-02")
    expect(sample_for("Due on receipt")).to include("due_date" => "2026-11-02")
    expect(sample_for(nil)).to include("payment_terms" => "Net 15", "due_date" => "2026-11-17")
  end

  it "leaves the due date blank for terms that do not imply one" do
    expect(sample_for("Payable upon completion of the engagement")).to include("due_date" => nil)
  end
end
