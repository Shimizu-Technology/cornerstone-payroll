# frozen_string_literal: true

require_relative "parity_helper"

RSpec.describe "Parity harness unit guards" do
  include Parity::CanonicalSchema

  describe "CanonicalSchema.assert_parity!" do
    it "passes when all views report the same populated value" do
      expect do
        assert_parity!(
          fixture: :sample,
          figure: :gross_pay,
          values_by_view: {
            employee_api: BigDecimal("1500.00"),
            client_pay_period: BigDecimal("1500.00"),
            staff_pay_period: BigDecimal("1500.00")
          }
        )
      end.not_to raise_error
    end

    it "fails when every view is missing a required figure (no vacuous pass)" do
      expect do
        assert_parity!(
          fixture: :sample,
          figure: :gross_pay,
          values_by_view: {
            employee_api: nil,
            client_pay_period: nil
          }
        )
      end.to raise_error(
        RSpec::Expectations::ExpectationNotMetError,
        /Missing required figure for \[sample\] `gross_pay` in view\(s\) \[employee_api, client_pay_period\]/
      )
    end

    it "fails when a single view is missing a required figure" do
      expect do
        assert_parity!(
          fixture: :sample,
          figure: :net_pay,
          values_by_view: {
            employee_api: BigDecimal("1200.00"),
            client_pay_period: nil
          }
        )
      end.to raise_error(
        RSpec::Expectations::ExpectationNotMetError,
        /Missing required figure for \[sample\] `net_pay` in view\(s\) \[client_pay_period\]/
      )
    end

    it "allows all-nil only when allow_nil: true is explicitly passed for optional figures" do
      expect do
        assert_parity!(
          fixture: :sample,
          figure: :address_line2,
          values_by_view: { employee_api: nil, client_api: nil },
          allow_nil: true
        )
      end.not_to raise_error
    end

    it "reports every divergent figure in one run when using assert_parity_table!" do
      views = {
        employee_api: { gross_pay: BigDecimal("100.00"), net_pay: BigDecimal("80.00") },
        staff_pay_period: { gross_pay: BigDecimal("101.00"), net_pay: BigDecimal("81.00") }
      }

      expect do
        assert_parity_table!(fixture: :sample, views: views, figures: %i[gross_pay net_pay])
      end.to raise_error(RSpec::Expectations::MultipleExpectationsNotMetError) do |error|
        expect(error.message).to include("`gross_pay`")
        expect(error.message).to include("`net_pay`")
      end
    end
  end

  describe "CanonicalSchema.normalize_check_number" do
    it "normalizes 6-digit check numbers and last-4 strings to the same 4-character token" do
      expect(normalize_check_number("105001")).to eq("5001")
      expect(normalize_check_number("5001")).to eq("5001")
      expect(normalize_check_number(" 105001 ")).to eq("5001")
      expect(normalize_check_number(nil)).to be_nil
      expect(normalize_check_number("")).to be_nil
    end
  end

  describe "CanonicalSchema.canonical_deduction_key" do
    it "maps pre-tax and Roth 401(k) label variants to shared canonical keys" do
      expect(canonical_deduction_key("401(k) Retirement")).to eq(:retirement_401k)
      expect(canonical_deduction_key("401(k) Pre-Tax")).to eq(:retirement_401k)
      expect(canonical_deduction_key("Roth 401(k)")).to eq(:roth_401k)
      expect(canonical_deduction_key("Roth 401(k) Contribution")).to eq(:roth_401k)
    end
  end

  describe "ClientApiExtractor handling of details_error rows" do
    it "returns details_available: false without raising on nil tax or retirement values" do
      extractor = Parity::Extractors::ClientApiExtractor.new(request_context: nil, headers: {})
      period = { "start_date" => "2026-01-19", "end_date" => "2026-02-01", "pay_date" => "2026-02-06", "run_purpose" => "regular" }
      item = {
        "employee_id" => 42,
        "employee_name" => "Test Worker",
        "gross_pay" => "1000.00",
        "net_pay" => "850.00",
        "hours_worked" => "40.00",
        "overtime_hours" => "0.00",
        "total_hours" => "40.00",
        "pay_stub_available" => false,
        "details_error" => "Pay line details are temporarily unavailable."
      }

      parsed = extractor.parse_pay_period_item(period, item)
      expect(parsed[:gross_pay]).to eq(BigDecimal("1000.00"))
      expect(parsed[:net_pay]).to eq(BigDecimal("850.00"))
      expect(parsed.dig(:status, :visible)).to eq(true)
      expect(parsed.dig(:status, :details_available)).to eq(false)
      expect(parsed.dig(:status, :details_error)).to eq("Pay line details are temporarily unavailable.")
    end
  end
end
