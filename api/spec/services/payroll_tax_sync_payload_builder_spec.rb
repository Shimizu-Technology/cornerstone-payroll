# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollTaxSyncPayloadBuilder, type: :service do
  let(:company) { create(:company, name: "Acme Corp", ein: "12-3456789") }
  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 1, 1),
      end_date: Date.new(2026, 1, 14),
      pay_date: Date.new(2026, 1, 19),
      tax_sync_idempotency_key: "cpr-1-1234567890"
    )
  end
  let(:employee) { create(:employee, company: company, first_name: "John", last_name: "Doe") }
  let!(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      gross_pay: 2400.00,
      net_pay: 1800.00,
      withholding_tax: 300.00,
      social_security_tax: 148.80,
      medicare_tax: 34.80,
      employer_social_security_tax: 148.80,
      employer_medicare_tax: 34.80,
      retirement_payment: 50.00
    )
  end

  subject(:builder) { described_class.new(pay_period) }

  describe "#build" do
    let(:payload) { builder.build }

    it "includes the idempotency key" do
      expect(payload[:idempotency_key]).to eq("cpr-1-1234567890")
    end

    it "includes source and version" do
      expect(payload[:source]).to eq("cornerstone-payroll")
      expect(payload[:version]).to eq("1.0")
    end

    it "includes submitted_at timestamp" do
      expect(payload[:submitted_at]).to be_present
    end

    describe "pay_period section" do
      it "includes correct pay period data" do
        pp = payload[:pay_period]
        expect(pp[:id]).to eq(pay_period.id)
        expect(pp[:start_date]).to eq("2026-01-01")
        expect(pp[:end_date]).to eq("2026-01-14")
        expect(pp[:pay_date]).to eq("2026-01-19")
        expect(pp[:committed_at]).to be_present
      end
    end

    describe "company section" do
      it "includes company info" do
        expect(payload[:company][:name]).to eq("Acme Corp")
        expect(payload[:company][:ein]).to eq("12-3456789")
      end
    end

    describe "line_items section" do
      it "includes one item per payroll item" do
        expect(payload[:line_items].size).to eq(1)
      end

      it "includes correct employee payroll data" do
        item = payload[:line_items].first
        expect(item[:employee_name]).to eq("John Doe")
        expect(item[:gross_pay]).to eq(2400.0)
        expect(item[:net_pay]).to eq(1800.0)
        expect(item[:withholding_tax]).to eq(300.0)
        expect(item[:social_security_tax]).to eq(148.8)
        expect(item[:medicare_tax]).to eq(34.8)
        expect(item[:employer_social_security_tax]).to eq(148.8)
        expect(item[:employer_medicare_tax]).to eq(34.8)
      end
    end

    describe "totals section" do
      it "sums all employee amounts" do
        totals = payload[:totals]
        expect(totals[:employee_count]).to eq(1)
        expect(totals[:gross_pay]).to eq(2400.0)
        expect(totals[:net_pay]).to eq(1800.0)
        expect(totals[:withholding_tax]).to eq(300.0)
        expect(totals[:total_tax_liability]).to be > 0
      end

      it "calculates total_tax_liability correctly" do
        totals = payload[:totals]
        expected = 300.0 + 148.8 + 34.8 + 148.8 + 34.8
        expect(totals[:total_tax_liability]).to eq(expected)
      end
    end
  end
end
