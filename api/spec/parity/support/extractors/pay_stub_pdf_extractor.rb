# frozen_string_literal: true

module Parity
  module Extractors
    # Extracts canonical figures directly from rendered PayStubGenerator PDF bytes
    # using pdf-reader and PdfBoxText (no ActiveRecord access).
    class PayStubPdfExtractor
      include Parity::CanonicalSchema
      include PdfBoxText

      TWO_AMOUNT_ROW = /\A(.+?)\s+(-?\$[\d,]+\.\d{2})\s+(-?\$[\d,]+\.\d{2})\z/
      ONE_AMOUNT_ROW = /\A(.+?)\s+(-?\$[\d,]+\.\d{2})\z/
      EARNING_ROW = /\A(.+?)\s+(—|-?[\d,]+\.\d{2})\s+(—|-?\$[\d,]+\.\d{2}(?:\/yr)?)\s+(-?\$[\d,]+\.\d{2})\s+(—|-?\$[\d,]+\.\d{2})\z/

      def extract(pdf_bytes)
        reader = PDF::Reader.new(StringIO.new(pdf_bytes))
        lines = reader.pages.flat_map { |page| pdf_rows(page) }.map(&:strip).reject(&:empty?)
        header_lines = reader.pages.first.text.lines(chomp: true).map(&:squish).reject(&:empty?)

        meta = parse_header_metadata(header_lines)
        sections = split_sections(lines)
        earnings = parse_earnings(sections["EARNINGS"] || [])
        deductions_and_taxes = parse_deductions_section(sections["DEDUCTIONS"] || [])
        other_pay = parse_two_amount_rows(sections["NON-TAXABLE ADDITIONS"] || [])
        employer_contributions = parse_employer_contributions(sections["EMPLOYER CONTRIBUTIONS"] || [])
        summary = parse_single_amount_rows(sections["SUMMARY"] || [])
        ytd_summary = parse_ytd_summary(sections["YEAR-TO-DATE SUMMARY"] || [])
        non_taxable_current = other_pay.values.sum(0.to_d) { |row| row[:amount].to_d }.round(2)

        {
          employee_name: meta[:employee_name],
          gross_pay: earnings[:gross_current] || summary["Gross Pay"],
          net_pay: summary["NET PAY"],
          non_taxable_pay: non_taxable_current,
          # The SUMMARY box's printed Taxes, not a sum of the rows (issue #637).
          taxes: deductions_and_taxes[:tax_amounts].merge(
            total_taxes: summary["Taxes"],
            total_taxes_from_rows: deductions_and_taxes[:tax_amounts][:total_taxes]
          ),
          tax_labels: deductions_and_taxes[:tax_labels],
          ytd_tax_labels: ytd_summary[:tax_labels],
          deductions: deductions_and_taxes[:deductions],
          employer_contributions: employer_contributions,
          other_pay: other_pay,
          earnings: earnings[:rows],
          hours: earnings[:hours],
          ytd: {
            gross: earnings[:gross_ytd] || ytd_summary[:values]["Gross Earnings"],
            income_tax: deductions_and_taxes[:tax_ytd][:income_tax],
            additional_withholding: deductions_and_taxes[:tax_ytd][:additional_withholding],
            total_income_tax: sum_present(
              deductions_and_taxes[:tax_ytd][:income_tax],
              deductions_and_taxes[:tax_ytd][:additional_withholding]
            ),
            social_security: deductions_and_taxes[:tax_ytd][:social_security],
            medicare_total: deductions_and_taxes[:tax_ytd][:medicare_total],
            retirement_401k: deductions_and_taxes[:deductions].dig(:retirement_401k, :ytd) || money(0),
            roth_401k: deductions_and_taxes[:deductions].dig(:roth_401k, :ytd) || money(0),
            deductions: ytd_summary[:values]["Deductions"],
            net: ytd_summary[:values]["Net Pay"]
          },
          dates: {
            period_start: meta[:period_start],
            period_end: meta[:period_end],
            pay_date: meta[:pay_date]
          },
          payment: {
            method: meta[:payment_method],
            **check_number_fields(meta[:check_number]),
            payment_label: meta[:payment_label]
          },
          raw_lines: lines
        }
      end

      private

      def parse_header_metadata(lines)
        meta = {}
        lines.each do |line|
          if (match = line.match(/\AEmployee:\s+(.+)\z/))
            meta[:employee_name] = match[1].strip
          elsif (match = line.match(/\APay Period:\s+(\d{2}\/\d{2}\/\d{4})\s*-\s*(\d{2}\/\d{2}\/\d{4})\z/))
            meta[:period_start] = iso_date(match[1])
            meta[:period_end] = iso_date(match[2])
          elsif (match = line.match(/\APay Date:\s+(\d{2}\/\d{2}\/\d{4})\z/))
            meta[:pay_date] = iso_date(match[1])
          elsif (match = line.match(/\APayment:\s+(.+)\z/))
            label = match[1].strip
            meta[:payment_label] = label
            if label.downcase.include?("direct deposit")
              meta[:payment_method] = "direct_deposit"
            elsif (chk = label.match(/Check #(\S+)/))
              meta[:payment_method] = "paper_check"
              meta[:check_number] = chk[1]
            end
          elsif (match = line.match(/\ACheck #:\s+(.+)\z/))
            value = match[1].strip
            meta[:payment_method] = "paper_check"
            meta[:check_number] = value unless value == "No check issued"
            meta[:payment_label] = "Check #: #{value}"
          end
        end
        meta
      end

      def split_sections(lines)
        headings = [
          "EARNINGS",
          "DEDUCTIONS",
          "NON-TAXABLE ADDITIONS",
          "EMPLOYER CONTRIBUTIONS",
          "SUMMARY",
          "YEAR-TO-DATE SUMMARY"
        ]
        sections = {}
        current = nil
        lines.each do |line|
          if headings.include?(line) || line.start_with?("SUMMARY ")
            current = line.start_with?("SUMMARY") ? "SUMMARY" : line
            sections[current] = []
          elsif current
            sections[current] << line
          end
        end
        sections
      end

      def parse_earnings(lines)
        rows = []
        gross_current = nil
        gross_ytd = nil
        regular = money(0)
        overtime = money(0)
        pto = money(0)
        holiday = money(0)

        lines.each do |line|
          next if line.start_with?("Description ")

          if (match = line.match(/\AGROSS PAY\s+(-?\$[\d,]+\.\d{2})\s+(-?\$[\d,]+\.\d{2})\z/))
            gross_current = money(match[1])
            gross_ytd = money(match[2])
          elsif (match = line.match(EARNING_ROW))
            label = match[1].strip
            hrs = hours(match[2])
            row = {
              label: label,
              hours: hrs,
              rate: match[3] == "—" ? nil : match[3],
              amount: money(match[4]),
              ytd: money(match[5])
            }
            rows << row
            next unless hrs

            down = label.downcase
            if down.include?("overtime") || down.match?(/\bot\b/)
              overtime = (overtime + hrs).round(2)
            elsif down.include?("pto")
              pto = (pto + hrs).round(2)
            elsif down.include?("holiday")
              holiday = (holiday + hrs).round(2)
            else
              regular = (regular + hrs).round(2)
            end
          end
        end

        {
          rows: rows,
          gross_current: gross_current,
          gross_ytd: gross_ytd,
          hours: {
            regular: regular,
            overtime: overtime,
            pto: pto,
            holiday: holiday,
            combined: (regular + overtime + pto + holiday).round(2)
          }
        }
      end

      def parse_deductions_section(lines)
        tax_amounts = {
          income_tax: money(0),
          additional_withholding: money(0),
          social_security: money(0),
          medicare_base: nil,
          additional_medicare: nil,
          medicare_total: money(0)
        }
        tax_ytd = {
          income_tax: money(0),
          additional_withholding: money(0),
          social_security: money(0),
          medicare_total: money(0)
        }
        tax_labels = {}
        deductions = {}
        medicare_row_amount = nil
        medicare_row_ytd = nil
        addl_med_ytd = nil

        lines.each do |line|
          next if line.start_with?("Description ") || line.start_with?("TOTAL DEDUCTIONS")
          next unless (match = line.match(TWO_AMOUNT_ROW))

          label = match[1].strip
          current = money(match[2])
          ytd = money(match[3])
          down = label.downcase

          if down.start_with?("additional medicare")
            tax_amounts[:additional_medicare] = current
            addl_med_ytd = ytd
            tax_labels[:additional_medicare] = label
          elsif down.include?("additional withholding") || down.include?("w-4 4c") || down.include?("extra guam income tax")
            tax_amounts[:additional_withholding] = current
            tax_ytd[:additional_withholding] = ytd
            tax_labels[:additional_withholding] = label
          elsif down.include?("income tax")
            tax_amounts[:income_tax] = current
            tax_ytd[:income_tax] = ytd
            tax_labels[:income_tax] = label
          elsif down.start_with?("social security")
            tax_amounts[:social_security] = current
            tax_ytd[:social_security] = ytd
            tax_labels[:social_security] = label
          elsif down.start_with?("medicare")
            medicare_row_amount = current
            medicare_row_ytd = ytd
            tax_labels[:medicare] = label
          else
            key = canonical_deduction_key(label)
            deductions[key] = { label: label, amount: current, ytd: ytd }
          end
        end

        if tax_amounts[:additional_medicare]
          tax_amounts[:medicare_base] = medicare_row_amount || money(0)
          tax_amounts[:medicare_total] = (tax_amounts[:medicare_base] + tax_amounts[:additional_medicare]).round(2)
          tax_ytd[:medicare_total] = sum_present(medicare_row_ytd, addl_med_ytd) || money(0)
        elsif medicare_row_amount
          tax_amounts[:medicare_total] = medicare_row_amount
          tax_ytd[:medicare_total] = medicare_row_ytd || money(0)
        end

        tax_amounts[:total_income_tax] = (tax_amounts[:income_tax] + tax_amounts[:additional_withholding]).round(2)
        tax_amounts[:total_taxes] = (tax_amounts[:total_income_tax] + tax_amounts[:social_security] + tax_amounts[:medicare_total]).round(2)

        {
          tax_amounts: tax_amounts,
          tax_ytd: tax_ytd,
          tax_labels: tax_labels,
          deductions: deductions
        }
      end

      def parse_two_amount_rows(lines)
        lines.each_with_object({}) do |line, acc|
          next if line.start_with?("Description ") || line.start_with?("TOTAL ")
          next unless (match = line.match(TWO_AMOUNT_ROW))

          label = match[1].strip
          key = label.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
          acc[key] = { label: label, amount: money(match[2]), ytd: money(match[3]) }
        end
      end

      def parse_employer_contributions(lines)
        lines.each_with_object({}) do |line, acc|
          next if line.start_with?("Description ") || line.start_with?("TOTAL ")
          next unless (match = line.match(TWO_AMOUNT_ROW))

          label = match[1].strip
          key = canonical_employer_contribution_key(label)
          acc[key] = { label: label, amount: money(match[2]), ytd: money(match[3]) }
        end
      end

      def parse_single_amount_rows(lines)
        lines.each_with_object({}) do |line, acc|
          next unless (match = line.match(ONE_AMOUNT_ROW))

          acc[match[1].strip] = money(match[2])
        end
      end

      def parse_ytd_summary(lines)
        values = {}
        tax_labels = {}
        lines.each do |line|
          next unless (match = line.match(ONE_AMOUNT_ROW))

          label = match[1].strip
          amount = money(match[2])
          values[label] = amount
          down = label.downcase
          if down.start_with?("additional withholding", "additional guam income tax")
            tax_labels[:additional_withholding] = label
          elsif down.include?("guam tax") || down.include?("income tax")
            tax_labels[:income_tax] = label
          end
          tax_labels[:social_security] = label if down == "social security"
          tax_labels[:medicare] = label if down == "medicare"
        end
        { values: values, tax_labels: tax_labels }
      end

      def sum_present(*values)
        present = values.compact
        return nil if present.empty?

        present.sum(0.to_d).round(2)
      end
    end
  end
end
