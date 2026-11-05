# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayStubGenerator do
  include ActiveSupport::Testing::TimeHelpers
  include HistoricalYtdBridgeFixtureHelper

  let(:company) { create(:company, name: "Stub Company") }
  let(:pay_period) do
    create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 14), pay_date: Date.new(2026, 4, 15))
  end
  let(:employee) do
    create(
      :employee,
      company: company,
      first_name: "Pat",
      last_name: "Stub",
      employment_type: "hourly",
      pay_rate: 20
    )
  end

  let(:payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      bonus: 50,
      reported_tips: 25,
      custom_earnings: [ { "label" => "Chief Stipend", "amount" => 75 } ],
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 40 } ],
      gross_pay: 310,
      net_pay: 250,
      ytd_gross: 310,
      ytd_net: 250
    )
  end

  describe "plain-paper pagination" do
    [ 3, 8 ].each do |count|
      it "fits #{count} additional deductions and non-taxable pay on one readable page" do
        company.update!(address_line2: "Suite 100")
        payroll_item.update!(bonus: 0, reported_tips: 0, custom_earnings: [], non_taxable_pay: 20,
          custom_deductions: count.times.map { |index| { "label" => "Deduction #{index + 1}", "amount" => 5 } })

        reader = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate))

        expect(reader.page_count).to eq(1)
        expect(reader.pages.first.text).to include("NON-TAXABLE ADDITIONS", "$20.00", "Deduction #{count}",
          "SUMMARY", "YEAR-TO-DATE SUMMARY", "Net Pay")
      end
    end

    [ 10, 12, 15, 20, 25, 30 ].each do |count|
      it "keeps both summary blocks intact with #{count} additional deductions" do
        payroll_item.update!(non_taxable_pay: 20,
          custom_deductions: count.times.map { |index| { "label" => "Deduction #{index + 1}", "amount" => 1 } })
        pages = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text)
        expect(pages.length).to eq(2)
        ytd_page = pages.find { |text| text.include?("YEAR-TO-DATE SUMMARY") }
        expect(ytd_page).to include("Gross Earnings", "Deductions", "Net Pay")
        current_page = pages.find { |text| text.match?(/SUMMARY\s+Current/) }
        expect(current_page).to include("Gross Pay", "NET PAY", "YEAR-TO-DATE SUMMARY", "Gross Earnings", "Net Pay")
        expect(current_page).to eq(ytd_page)
      end
    end
  end

  it "shows historical reimbursements in non-taxable additions without inflating displayed gross earnings" do
    apply_historical_ytd_balance(
      company: company, employee: employee,
      through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
      gross_pay: 2_000, non_taxable_pay: 300,
      source_breakdown: { "earnings_breakdown" => { "Regular Pay" => "1700", "Reimb" => "300" } }
    )
    payroll_item.update!(ytd_gross: 2_310)

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("NON-TAXABLE ADDITIONS", "Reimb", "$2,010.00")
    expect(text).not_to include("$2,310.00")
    expect(payroll_item.reload.ytd_gross).to eq(2_310.to_d)
  end

  it "uses the active bridge revision for both YTD gross and the reimbursement offset" do
    apply_historical_ytd_balance(
      company: company, employee: employee,
      through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
      gross_pay: 2_000, non_taxable_pay: 300,
      source_breakdown: { "earnings_breakdown" => { "Regular Pay" => "1700", "Reimb" => "300" } }
    )
    payroll_item.update!(ytd_gross: 2_310)
    apply_historical_ytd_balance(
      company: company, employee: employee,
      through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
      gross_pay: 2_200, non_taxable_pay: 400,
      source_breakdown: { "earnings_breakdown" => { "Regular Pay" => "1800", "Reimb" => "400" } }
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("$2,110.00")
    expect(text).not_to include("$2,010.00", "$2,310.00")
  end

  it "includes the current paycheck in a draft pay stub preview" do
    draft_period = create(:pay_period, company: company,
      start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 14), pay_date: Date.new(2026, 4, 15))
    draft_item = create(:payroll_item, pay_period: draft_period, employee: employee, company: company,
      employment_type: "hourly", gross_pay: 310, ytd_gross: 310)

    text = PDF::Reader.new(StringIO.new(described_class.new(draft_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("$310.00")
  end

  it "identifies a zero-net earnings statement without implying a deposit or missing check" do
    payroll_item.update!(payment_delivery_method: "direct_deposit", net_pay: 0)

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n").gsub(/\s+/, " ")

    expect(text).to include("Earnings statement only - no payment issued", "$0.00", "$310.00")
    expect(text).not_to include("Direct deposit", "No check issued")
  end

  it "retains a historical check reference on a nonpositive adjustment statement" do
    payroll_item.update_columns(net_pay: -20, check_number: "8101")

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n").gsub(/\s+/, " ")

    expect(text).to include("Earnings statement only - no payment issued", "Check reference: 8101")
  end

  it "does not label missing check numbers as direct deposit" do
    payroll_item.update!(check_number: nil)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n").gsub(/\s+/, " ")

    expect(text).to include("Check #: No check issued")
    expect(text).not_to include("Direct Deposit")
  end

  it "prints supplemental earnings even when stored earning rows are partial" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Regular Pay")
    expect(text).to include("Bonus")
    expect(text).to include("Reported Tips")
    expect(text).to include("Chief Stipend")
  end

  def taxable_bonus_field(item, amount: 50, source: "manual")
    definition = item.company.payroll_field_definitions.find_or_create_by!(name: "Bonus") do |field|
      field.kind = "addition"
      field.tax_treatment = "taxable_addition"
      field.category = "other"
    end
    item.payroll_item_field_entries.create!(payroll_field_definition: definition,
      label: "Bonus", kind: "addition", tax_treatment: "taxable_addition", category: "other",
      amount: amount, source: source, active: true)
  end

  def earnings_table(item)
    generator = described_class.new(item)
    pdf = Prawn::Document.new
    rows = nil
    allow(pdf).to receive(:table) { |data, **_options| rows = data }
    generator.send(:render_earnings, pdf)
    rows.drop(1).take(rows.length - 2)
  end

  it "prints a calculated salary field bonus once with its YTD, preserving gross" do
    payroll_item.update!(employment_type: "salary", bonus: 0, reported_tips: 0,
      custom_earnings: [], gross_pay: 1050)
    taxable_bonus_field(payroll_item)
    payroll_item.payroll_item_earnings.create!(category: "salary", label: "Salary", amount: 1000)
    payroll_item.payroll_item_earnings.create!(category: "other", label: "Bonus", amount: 50)
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item, company: company, employee: employee, pay_period: prior_period, gross_pay: 50)
    taxable_bonus_field(prior_item)

    rows = earnings_table(payroll_item)
    expect(rows.select { |row| row.first == "Bonus" }).to eq([ [ "Bonus", "—", "—", "$50.00", "$100.00" ] ])
    expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(payroll_item.gross_pay)
    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")
    expect(text.scan(/\bBonus\b/).length).to eq(1)
  end

  it "preserves a separate one-time bonus beside the same-label field mirror" do
    payroll_item.update!(reported_tips: 0, custom_earnings: [], gross_pay: 260)
    taxable_bonus_field(payroll_item)
    payroll_item.payroll_item_earnings.create!(category: "regular", label: "Regular Pay", amount: 160)
    payroll_item.payroll_item_earnings.create!(category: "bonus", label: "Bonus", amount: 50)
    payroll_item.payroll_item_earnings.create!(category: "other", label: "Bonus", amount: 50)

    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item, company: company, employee: employee, pay_period: prior_period, gross_pay: 50)
    taxable_bonus_field(prior_item)
    rows = earnings_table(payroll_item)
    expect(rows.count { |row| row.first == "Bonus" }).to eq(2)
    expect(rows).to include([ "Bonus", "—", "—", "$50.00", "$100.00" ])
    expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(payroll_item.gross_pay)
  end

  [ "salary", "hourly", "contractor" ].each do |type|
    it "keeps legacy #{type} earnings and imported fields equal to gross" do
      payroll_item.update!(employee: create(:employee, :contractor, company: company)) if type == "contractor"
      payroll_item.update!(employment_type: type, bonus: 50, reported_tips: 0,
        custom_earnings: [], service_charge_wages: 25, gross_pay: type == "hourly" ? 285 : 1125)
      taxable_bonus_field(payroll_item, source: "import")

      rows = earnings_table(payroll_item)
      expect(rows.count { |row| row.first == "Bonus" }).to eq(2)
      expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(payroll_item.gross_pay)
    end
  end

  [ SalaryPayrollCalculator, HourlyPayrollCalculator, ContractorPayrollCalculator ].each do |calculator_class|
    it "does not duplicate taxable fields materialized by #{calculator_class}" do
      type = { SalaryPayrollCalculator => "salary", HourlyPayrollCalculator => "hourly",
        ContractorPayrollCalculator => "contractor" }.fetch(calculator_class)
      worker = create(:employee, type.to_sym, company: company)
      item = create(:payroll_item, employee: worker, company: company, pay_period: pay_period,
        employment_type: type, pay_rate: type == "salary" ? 26_000 : 20, hours_worked: 8)
      taxable_bonus_field(item)
      calculator = calculator_class.new(worker, item)
      calculator.send(:calculate_gross_pay)
      calculator.send(:record_earnings_breakdown)
      item.save!

      expect(item.bonus).to be_zero
      expect(item.payroll_item_earnings.select { |earning| earning.label == "Bonus" }.map(&:category)).to eq([ "other" ])
      rows = earnings_table(item)
      expect(rows.count { |row| row.first == "Bonus" }).to eq(1)
      expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(item.gross_pay)
      expect(PayrollEarningsYtdBreakdown.new(item).call.sum(&:current)).to eq(item.gross_pay)
      expect(PayrollItemDisclosure.new(item).as_json[:earnings].sum { |row| row[:amount].to_d }).to eq(item.gross_pay)
    end
  end

  it "retains the residual contract fee for a legacy zero-hour hourly contractor" do
    worker = create(:employee, :contractor, company: company, contractor_pay_type: "hourly")
    payroll_item.update!(employee: worker, employment_type: "contractor", hours_worked: 0,
      bonus: 0, reported_tips: 0, custom_earnings: [], gross_pay: 1000)

    rows = earnings_table(payroll_item)
    expect(rows.first.first).to eq("Contract Fee")
    expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(payroll_item.gross_pay)
  end

  it "shows negative saved service charges rather than inflating legacy salary" do
    payroll_item.update!(employment_type: "salary", bonus: 0, reported_tips: 0,
      custom_earnings: [], service_charge_wages: -25, gross_pay: 975)

    rows = earnings_table(payroll_item)
    expect(rows).to include([ "Service Charges", "—", "—", "$-25.00", "$-25.00" ])
    expect(rows.map { |row| row[3].delete("$,").to_d }.sum).to eq(payroll_item.gross_pay)
  end

  describe "per-row earnings YTD" do
    def calculated_item(worker, type, pay_date, **attributes)
      period = create(:pay_period, :committed, company: company, start_date: pay_date - 14, end_date: pay_date - 4, pay_date: pay_date)
      item = create(:payroll_item, company: company, employee: worker, pay_period: period, employment_type: type,
        pay_rate: worker.pay_rate, hours_worked: 0, **attributes)
      yield item if block_given?
      calculator = { "hourly" => HourlyPayrollCalculator, "salary" => SalaryPayrollCalculator,
        "contractor" => ContractorPayrollCalculator }.fetch(type).new(worker, item)
      calculator.send(:calculate_gross_pay)
      calculator.send(:record_earnings_breakdown)
      item.save!
      item
    end

    def hourly_worker = create(:employee, :hourly, company: company, pay_rate: 14.37)
    def salaried_worker = create(:employee, :salary, company: company, pay_rate: 41_234.56, pay_frequency: "biweekly")

    def statement_rows(item) = earnings_table(PayrollItem.find(item.id))

    def statement_lines(item)
      reader = PDF::Reader.new(StringIO.new(described_class.new(PayrollItem.find(item.id)).generate))
      [ reader.page_count, reader.pages.map(&:text).join("\n").gsub(/ +/, " ") ]
    end

    def money(cell) = cell.delete("$,").to_d

    def expect_rows_to_foot(item, rows)
      gross_ytd = described_class.new(item).send(:pay_ytd_total)
      expect(rows.sum { |row| money(row[3]) }).to eq(item.gross_pay)
      expect(rows.sum { |row| money(row[4]) }).to eq(gross_ytd)
    end

    it "prints wages, overtime and tips with their own YTD in the rendered statement" do
      worker = hourly_worker
      3.times do |index|
        calculated_item(worker, "hourly", Date.new(2026, 1, 15) + (index * 14), hours_worked: 76.33, overtime_hours: 2.25, reported_tips: 212.15)
      end
      item = calculated_item(worker, "hourly", Date.new(2026, 2, 26), hours_worked: 80.5, overtime_hours: 3.75, reported_tips: 188.4)

      rows = statement_rows(item)
      expect(rows).to eq([
        [ "Regular Pay", "80.50", "$14.37", "$1,156.79", "$4,447.37" ],
        [ "Overtime Pay", "3.75", "$21.56", "$80.83", "$226.33" ],
        [ "Tips", "—", "—", "$188.40", "$824.85" ]
      ])
      expect_rows_to_foot(item, rows)

      page_count, text = statement_lines(item)
      expect(page_count).to eq(1)
      expect(text).to include("Regular Pay 80.50 $14.37 $1,156.79 $4,447.37", "Tips — — $188.40 $824.85", "GROSS PAY $1,426.02 $5,498.55")
    end

    it "prints salary, bonus, service charges and other earnings with their own YTD" do
      worker = salaried_worker
      calculated_item(worker, "salary", Date.new(2026, 1, 15), bonus: 250, service_charge_wages: 310.55)
      calculated_item(worker, "salary", Date.new(2026, 1, 29), service_charge_wages: 95.2)
      item = calculated_item(worker, "salary", Date.new(2026, 2, 12), bonus: 100, service_charge_wages: 45.75,
        custom_earnings: [ { "label" => "Chief Stipend", "amount" => 75 } ])

      rows = statement_rows(item)
      expect(rows).to contain_exactly(
        [ "Salary", "—", "—", "$1,585.94", "$4,757.82" ],
        [ "Service Charges", "—", "—", "$45.75", "$451.50" ],
        [ "Bonus", "—", "—", "$100.00", "$350.00" ],
        [ "Chief Stipend", "—", "—", "$75.00", "$75.00" ]
      )
      expect_rows_to_foot(item, rows)
    end

    it "keeps earlier components on the statement when they are absent from this paycheck" do
      worker = hourly_worker
      calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80, reported_tips: 150, bonus: 300)
      worker.update!(employment_type: "salary", pay_rate: 41_234.56, salary_type: "annual", pay_frequency: "biweekly")
      item = calculated_item(worker, "salary", Date.new(2026, 1, 29))

      rows = statement_rows(item)
      expect(rows.first).to eq([ "Salary", "—", "—", "$1,585.94", "$1,585.94" ])
      expect(rows.drop(1)).to contain_exactly(
        [ "Regular Pay", "—", "—", "$0.00", "$1,149.60" ],
        [ "Tips", "—", "—", "$0.00", "$150.00" ],
        [ "Bonus", "—", "—", "$0.00", "$300.00" ]
      )
      expect_rows_to_foot(item, rows)
      expect(statement_lines(item).first).to eq(1)
    end

    it "keeps both summaries together when many earlier components lengthen the statement" do
      worker = hourly_worker
      calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80, overtime_hours: 4, holiday_hours: 8, pto_hours: 8,
        reported_tips: 150, bonus: 300, service_charge_wages: 20,
        custom_earnings: (1..4).map { |index| { "label" => "Stipend #{index}", "amount" => 10 * index } })
      item = calculated_item(worker, "hourly", Date.new(2026, 1, 29), hours_worked: 80, non_taxable_pay: 20,
        custom_deductions: (1..8).map { |index| { "label" => "Deduction #{index}", "amount" => 5 } })

      reader = PDF::Reader.new(StringIO.new(described_class.new(PayrollItem.find(item.id)).generate))
      expect(reader.page_count).to eq(2)
      expect(reader.pages.first.text).to include("GROSS PAY", "TOTAL DEDUCTIONS")
      expect(reader.pages.last.text).to include("NET PAY", "YEAR-TO-DATE SUMMARY", "Gross Earnings", "Net Pay")
    end

    it "itemizes items saved without earning rows under their existing labels" do
      worker = salaried_worker
      prior = calculated_item(worker, "salary", Date.new(2026, 1, 15), bonus: 100)
      item = calculated_item(worker, "salary", Date.new(2026, 1, 29), service_charge_wages: 20)
      [ prior, item ].each { |saved| saved.payroll_item_earnings.destroy_all }

      rows = statement_rows(item)
      expect(rows).to eq([
        [ "Salary", "—", "$41,234.56/yr", "$1,585.94", "$3,171.88" ],
        [ "Service Charges", "—", "—", "$20.00", "$20.00" ],
        [ "Bonus", "—", "—", "$0.00", "$100.00" ]
      ])
      expect_rows_to_foot(item, rows)

      worker = hourly_worker
      prior = calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80, overtime_hours: 2, reported_tips: 50)
      item = calculated_item(worker, "hourly", Date.new(2026, 1, 29), hours_worked: 80, reported_tips: 25)
      [ prior, item ].each { |saved| saved.payroll_item_earnings.destroy_all }

      rows = statement_rows(item)
      expect(rows.first(2)).to eq([
        [ "Regular", "80.00", "$14.37", "$1,149.60", "$2,299.20" ],
        [ "Reported Tips", "—", "—", "$25.00", "$75.00" ]
      ])
      expect(rows.last).to eq([ "Overtime Pay", "—", "—", "$0.00", "$43.11" ])
      expect_rows_to_foot(item, rows)
    end

    it "carries an itemized opening balance into the rows without its reimbursements" do
      worker = hourly_worker
      apply_historical_ytd_balance(company: company, employee: worker,
        through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
        gross_pay: 5_300, non_taxable_pay: 300,
        source_breakdown: { "earnings_breakdown" => { "Hourly Pay" => "4000", "Overtime" => "400", "Paycheck Tips" => "600", "Reimb" => "300" } })
      item = calculated_item(worker, "hourly", Date.new(2026, 4, 15), hours_worked: 80, overtime_hours: 2, reported_tips: 80)

      rows = statement_rows(item)
      expect(rows).to contain_exactly(
        [ "Regular Pay", "80.00", "$14.37", "$1,149.60", "$1,149.60" ],
        [ "Overtime Pay", "2.00", "$21.56", "$43.11", "$443.11" ],
        [ "Tips", "—", "—", "$80.00", "$680.00" ],
        [ "Hourly Pay", "—", "—", "$0.00", "$4,000.00" ]
      )
      expect_rows_to_foot(item, rows)
    end

    context "when row YTD cannot be derived" do
      it "keeps dashes for an opening balance that was not itemized and retains the YTD total" do
        worker = hourly_worker
        apply_historical_ytd_balance(company: company, employee: worker,
          through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
          gross_pay: 5_000, non_taxable_pay: 0, source_breakdown: {})
        item = calculated_item(worker, "hourly", Date.new(2026, 4, 15), hours_worked: 80, reported_tips: 80)

        expect(statement_rows(item)).to eq([
          [ "Regular Pay", "80.00", "$14.37", "$1,149.60", "—" ],
          [ "Tips", "—", "—", "$80.00", "—" ]
        ])
        expect(statement_lines(item).last).to include("GROSS PAY $1,229.60 $6,229.60")
      end

      it "keeps dashes when same-label rows cannot be attributed separately" do
        worker = salaried_worker
        item = calculated_item(worker, "salary", Date.new(2026, 1, 15),
          custom_earnings: [ { "label" => "Stipend", "amount" => 25 } ])
        item.payroll_item_earnings.destroy_all
        item.update!(custom_earnings: [ { "label" => "Stipend", "amount" => 25 }, { "label" => "Stipend", "amount" => 30 } ],
          gross_pay: item.gross_pay + 30)

        rows = statement_rows(item)
        expect(rows.map(&:last).uniq).to eq([ "—" ])
        expect(rows.map(&:first)).to include("Salary", "Stipend")
      end

      it "keeps dashes on a correction without stored earning rows" do
        worker = hourly_worker
        original = calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80)
        period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 1, 16), end_date: Date.new(2026, 1, 20), pay_date: Date.new(2026, 1, 29))
        correction = create(:payroll_item, company: company, employee: worker, pay_period: period, employment_type: "hourly",
          pay_rate: 14.37, hours_worked: 0, gross_pay: -143.70, net_pay: 0, correction_for_payroll_item_id: original.id)

        expect(statement_rows(correction)).to eq([ [ "Taxable earnings adjustment", "—", "—", "$-143.70", "—" ] ])
      end
    end

    context "when an applied opening balance has a malformed earnings breakdown" do
      [ nil, [], [ { "label" => "Regular Pay", "amount" => "5000" } ], "not itemized", 7, { "Regular Pay" => "NaN" }, { "Reimb" => "NaN" } ].each do |breakdown|
        it "renders with dashes and the YTD total for #{breakdown.inspect}" do
          worker = hourly_worker
          apply_historical_ytd_balance(company: company, employee: worker,
            through_period_end: Date.new(2026, 3, 31), through_pay_date: Date.new(2026, 4, 1),
            gross_pay: 5_000, non_taxable_pay: 0, source_breakdown: { "earnings_breakdown" => breakdown })
          item = calculated_item(worker, "hourly", Date.new(2026, 4, 15), hours_worked: 80, reported_tips: 80)

          expect(statement_rows(item)).to eq([
            [ "Regular Pay", "80.00", "$14.37", "$1,149.60", "—" ],
            [ "Tips", "—", "—", "$80.00", "—" ]
          ])
          text = statement_lines(item).last
          expect(text).to include("GROSS PAY $1,229.60 $6,229.60")
          expect(text).not_to include("NaN")
        end
      end
    end

    context "when taxable payroll fields share a label" do
      def allowance(item, amount, category:)
        item.payroll_item_field_entries.create!(label: "Allowance", kind: "addition", tax_treatment: "taxable_addition",
          category: category, amount: amount, source: "manual", active: true)
      end

      it "keeps the current field's own YTD when another field's mirror has the same label" do
        worker = salaried_worker
        calculated_item(worker, "salary", Date.new(2026, 1, 15)) { |item| allowance(item, 100, category: "benefit") }
        item = calculated_item(worker, "salary", Date.new(2026, 1, 29)) { |saved| allowance(saved, 50, category: "other") }

        expect(statement_rows(item)).to eq([
          [ "Salary", "—", "—", "$1,585.94", "—" ],
          [ "Allowance", "—", "—", "$50.00", "$50.00" ]
        ])
      end

      it "keeps dashes when different fields would merge into an earlier-component row" do
        worker = salaried_worker
        calculated_item(worker, "salary", Date.new(2026, 1, 15)) { |item| allowance(item, 100, category: "benefit") }
        calculated_item(worker, "salary", Date.new(2026, 1, 29)) { |item| allowance(item, 50, category: "other") }
        item = calculated_item(worker, "salary", Date.new(2026, 2, 12))

        expect(statement_rows(item)).to eq([ [ "Salary", "—", "—", "$1,585.94", "—" ] ])
      end

      it "keeps dashes when a one-time earning shares the field's label" do
        worker = salaried_worker
        calculated_item(worker, "salary", Date.new(2026, 1, 15), custom_earnings: [ { "label" => "Allowance", "amount" => 100 } ])
        item = calculated_item(worker, "salary", Date.new(2026, 1, 29)) { |saved| allowance(saved, 50, category: "other") }

        expect(statement_rows(item)).to include([ "Allowance", "—", "—", "$50.00", "$50.00" ], [ "Salary", "—", "—", "$1,585.94", "—" ])
      end

      it "itemizes the field when one identity carries through the year" do
        worker = salaried_worker
        calculated_item(worker, "salary", Date.new(2026, 1, 15)) { |item| allowance(item, 100, category: "other") }
        item = calculated_item(worker, "salary", Date.new(2026, 1, 29)) { |saved| allowance(saved, 50, category: "other") }

        rows = statement_rows(item)
        expect(rows).to contain_exactly(
          [ "Salary", "—", "—", "$1,585.94", "$3,171.88" ],
          [ "Allowance", "—", "—", "$50.00", "$150.00" ]
        )
        expect_rows_to_foot(item, rows)
      end
    end

    context "with contractor items saved without earning rows" do
      def contractor(pay_type) = create(:employee, :contractor, company: company, pay_rate: 20, contractor_pay_type: pay_type)

      def unstored_contractor_item(worker, pay_date, saved_pay_type:, **attributes)
        period = create(:pay_period, :committed, company: company, start_date: pay_date - 14, end_date: pay_date - 4, pay_date: pay_date)
        snapshot = saved_pay_type ? { "employee" => { "contractor_pay_type" => saved_pay_type } } : {}
        create(:payroll_item, company: company, employee: worker, pay_period: period, employment_type: "contractor", pay_rate: 20,
          hours_worked: 0, **attributes).tap { |item| item.update_columns(calculation_context_snapshot: snapshot) }
      end

      it "keeps an hourly contractor's override as a contract fee rather than hours" do
        item = unstored_contractor_item(contractor("hourly"), Date.new(2026, 1, 15), saved_pay_type: "hourly",
          salary_override: 200, hours_worked: 10, gross_pay: 200)

        expect(statement_rows(item)).to eq([ [ "Contract Fee", "—", "$20.00", "$200.00", "—" ] ])
      end

      it "does not fold a saved flat fee into hourly YTD after the profile changes" do
        worker = contractor("flat_fee")
        unstored_contractor_item(worker, Date.new(2026, 1, 15), saved_pay_type: "flat_fee", hours_worked: 25, gross_pay: 500)
        worker.update!(contractor_pay_type: "hourly")
        item = calculated_item(worker, "contractor", Date.new(2026, 1, 29), hours_worked: 10)

        expect(statement_rows(item)).to eq([ [ "Contract Labor", "10.00", "$20.00", "$200.00", "—" ] ])
      end

      it "keeps dashes when no saved pay basis exists" do
        item = unstored_contractor_item(contractor("flat_fee"), Date.new(2026, 1, 15), saved_pay_type: nil, gross_pay: 500)

        expect(statement_rows(item)).to eq([ [ "Contract Fee", "—", "$20.00", "$500.00", "—" ] ])
      end

      it "itemizes when the saved basis agrees with the profile" do
        worker = contractor("flat_fee")
        unstored_contractor_item(worker, Date.new(2026, 1, 15), saved_pay_type: "flat_fee", gross_pay: 500)
        item = unstored_contractor_item(worker, Date.new(2026, 1, 29), saved_pay_type: "flat_fee", gross_pay: 300)

        rows = statement_rows(item)
        expect(rows).to eq([ [ "Contract Fee", "—", "$20.00", "$300.00", "$800.00" ] ])
        expect_rows_to_foot(item, rows)
      end
    end

    context "when stored earning rows omit saved earnings whose amounts cancel" do
      def omit_offsetting_earnings(item)
        item.update_columns(bonus: 25, service_charge_wages: -25)
      end

      it "prints the saved earnings with dashes on the current statement" do
        item = calculated_item(hourly_worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80)
        omit_offsetting_earnings(item)

        expect(statement_rows(item)).to eq([
          [ "Regular Pay", "80.00", "$14.37", "$1,149.60", "—" ],
          [ "Bonus", "—", "—", "$25.00", "—" ],
          [ "Service Charges", "—", "—", "$-25.00", "—" ]
        ])
      end

      it "keeps dashes on later statements because the earlier omission cannot be attributed" do
        worker = hourly_worker
        omit_offsetting_earnings(calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80))
        item = calculated_item(worker, "hourly", Date.new(2026, 1, 29), hours_worked: 80)

        expect(statement_rows(item)).to eq([ [ "Regular Pay", "80.00", "$14.37", "$1,149.60", "—" ] ])
      end
    end

    it "does not change the saved payroll record" do
      worker = hourly_worker
      item = calculated_item(worker, "hourly", Date.new(2026, 1, 15), hours_worked: 80, reported_tips: 20)
      before = item.reload.attributes

      described_class.new(item).generate

      expect(item.reload.attributes).to eq(before)
    end
  end

  it "prints legacy insurance and loan YTD values when those rows are visible" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    create(
      :payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      insurance_payment: 30,
      loan_payment: 15,
      gross_pay: 160,
      net_pay: 115,
      total_deductions: 45
    )
    payroll_item.update!(insurance_payment: 10, loan_payment: 5, total_deductions: payroll_item.total_deductions.to_f + 15)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Health Insurance")
    expect(text).to include("Loan Repayment")
    expect(text).to include("$40.00")
    expect(text).to include("$20.00")
  end

  it "prints a direct loan and a separate named loan field on the same stub" do
    field = PayrollFieldDefinition.create!(company: company, name: "Loan - Madela Severin",
      kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan", amount_type: "fixed")
    payroll_item.payroll_item_field_entries.create!(payroll_field_definition: field,
      label: field.name, kind: "deduction", tax_treatment: "post_tax_deduction",
      category: "loan", amount: BigDecimal("250"), source: "employee_default")
    payroll_item.update!(loan_deduction: BigDecimal("428.36"), loan_payment: BigDecimal("678.36"))

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Loan Repayment")
    expect(text).to include("Loan - Madela Severin")
    expect(text).to include("$428.36")
    expect(text).to include("$250.00")
  end

  it "prints legacy itemized deductions and includes them in YTD total deductions" do
    deduction_type = DeductionType.create!(
      company: company,
      name: "Garnishment",
      category: "post_tax",
      sub_category: "garnishment"
    )
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      label: "Garnishment",
      category: "post_tax",
      amount: 12
    )
    payroll_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      label: "Garnishment",
      category: "post_tax",
      amount: 8
    )
    payroll_item.update!(custom_deductions: [])

    generator = described_class.new(payroll_item)
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

    expect(text).to include("Garnishment")
    expect(text).to include("$20.00")
    expect(generator.send(:ytd_total_deductions)).to eq(20.0)
  end

  it "prints custom deductions by label" do
    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
  end

  it "prints treatment-aware payroll adjustments by label without duplicating non-taxable earnings" do
    payroll_item.update!(
      payroll_adjustments: [
        { "label" => "Taxable Bonus", "amount" => 100.0, "treatment" => "taxable_addition", "active" => true },
        { "label" => "Reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true },
        { "label" => "Pre-Tax Deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction", "active" => true },
        { "label" => "Post-Tax Deduction", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true }
      ]
    )
    payroll_item.payroll_item_earnings.create!(category: "non_taxable", label: "Reimbursement", amount: 25.0)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Taxable Bonus")
    expect(text).to include("NON-TAXABLE ADDITIONS")
    expect(text.scan("Reimbursement").count).to eq(1)
    expect(text).to include("Pre-Tax Deduction")
    expect(text).to include("Post-Tax Deduction")
  end

  it "prints total employer contribution YTD on pay stubs" do
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance"
    )
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance",
      amount: 15,
      source: "manual",
      employee_paid: false,
      employer_paid: true
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance",
      amount: 10,
      source: "manual",
      employee_paid: false,
      employer_paid: true
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("TOTAL EMPLOYER CONTRIBUTIONS")
    expect(text).to include("$25.00")
  end

  it "uses stored tax snapshots and source-backed retirement in total deductions YTD" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      withholding_tax: 999,
      social_security_tax: 999,
      medicare_tax: 999,
      retirement_payment: 999,
      roth_retirement_payment: 999)
    payroll_item.update!(
      ytd_withholding_tax: 10,
      ytd_social_security_tax: 20,
      ytd_medicare_tax: 5,
      ytd_retirement: 30,
      ytd_roth_retirement: 7,
      custom_deductions: []
    )

    expect(described_class.new(payroll_item).send(:ytd_total_deductions)).to eq(2033.0)
  end

  it "keeps field histories separate while including all saved deductions in the YTD total" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_field_entries.create!(
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "insurance",
      amount: 999,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 20,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      label: "Uniform",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "insurance",
      amount: 5,
      source: "manual"
    )

    generator = described_class.new(payroll_item)

    rent_entry = payroll_item.payroll_item_field_entries.find_by!(label: "Rent Deduction")
    expect(generator.send(:ytd_payroll_field_amount, rent_entry)).to eq(20.0)
    expect(PayrollStatementYtdBreakdown.new(payroll_item).deductions.sum(0.to_d, &:ytd)).to eq(1064.0)
  end

  it "prints earlier additional withholding when the current check has none" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      additional_withholding: 15)

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")
    row = text.lines.find { |line| line.include?("Additional Withholding") }

    expect(row).to include("$0.00", "$15.00")
  end

  it "limits payroll field YTD values to the current calendar year" do
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent"
    )
    prior_year_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2025, 12, 31))
    prior_year_item = create(:payroll_item,
      pay_period: prior_year_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_year_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 80,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 20,
      source: "manual"
    )

    entry = payroll_item.payroll_item_field_entries.find { |candidate| candidate.label == "Rent Deduction" }
    generator = described_class.new(payroll_item)

    expect(generator.send(:ytd_payroll_field_amount, entry)).to eq(20.0)
  end

  it "does not include later same-pay-date custom deductions in YTD custom deduction totals" do
    later_period = create(
      :pay_period,
      :committed,
      company: company,
      pay_date: pay_period.pay_date
    )
    create(
      :payroll_item,
      pay_period: later_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 60 } ],
      total_deductions: 60,
      gross_pay: 160,
      net_pay: 100
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
    expect(text).to include("$40.00")
    expect(text).not_to include("$100.00")
  end

  %w[calculated committed].each do |status|
    it "reconciles non-taxable pay, deductions and additional withholding in the #{status} YTD summary" do
      pay_period.update!(status: status, committed_at: status == "committed" ? Time.current : nil)
      payroll_item.update!(pay_rate: 10, hours_worked: 10, bonus: 0, reported_tips: 0, custom_earnings: [],
        gross_pay: 100, non_taxable_pay: 20, withholding_tax: 5,
        social_security_tax: 6.20, medicare_tax: 1.45, additional_withholding: 3,
        custom_deductions: [ { "label" => "Cash Advance", "amount" => 9 } ],
        total_deductions: 24.65, net_pay: 95.35, ytd_gross: 100,
        ytd_withholding_tax: 5, ytd_social_security_tax: 6.20, ytd_medicare_tax: 1.45, ytd_net: 95.35)

      reader = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate))
      ytd = reader.pages.map(&:text).join("\n").split("YEAR-TO-DATE SUMMARY").last.gsub(/\s+/, " ")
      expect(ytd).to include("Gross Earnings $100.00", "Non-Taxable Pay $20.00", "Additional Withholding $3.00",
        "Federal/Guam Tax $5.00", "Social Security $6.20", "Medicare $1.45", "Deductions $9.00", "Net Pay $95.35")
      expect(reader.page_count).to eq(1)
    end
  end

  it "keeps a standard earnings statement to one page" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate

    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to eq(1)
  end

  it "prints the generated timestamp in Guam time" do
    travel_to Time.utc(2026, 4, 29, 19, 48) do
      pdf = described_class.new(payroll_item).generate
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

      expect(text).to include("Generated on April 30, 2026 at 05:48 AM ChST")
    end
  end

  it "lets dense earnings statements flow to additional content pages without a footer-only page" do
    120.times do |index|
      payroll_item.payroll_item_earnings.create!(
        category: "other",
        label: "Supplemental Earning #{index + 1}",
        amount: 10 + index
      )
    end

    pdf = described_class.new(payroll_item).generate
    pages = PDF::Reader.new(StringIO.new(pdf)).pages

    expect(pages.count).to be > 1
    # SQL does not promise association order, and totals may occupy a final
    # content page. Verify every earning and distinguish content from a footer.
    earning_numbers = pages.flat_map { |page| page.text.scan(/Supplemental\s+Earning\s+(\d+)\b/).flatten.map(&:to_i) }
    expect(earning_numbers.sort).to eq((1..120).to_a)
    expect(pages.last.text).to match(/Supplemental\s+Earning|NET\s+PAY|YEAR-TO-DATE\s+SUMMARY/)
    expect(pages.last.text).to include("Generated on")
  end
end
