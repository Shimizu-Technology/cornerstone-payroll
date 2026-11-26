# frozen_string_literal: true

module Parity
  module Extractors
    # Extracts canonical figures directly from CheckGenerator PDF bytes using
    # pdf-reader and PdfBoxText coordinate boxes matching the top-check 4-quadrant
    # layout so left and right stub columns stay cleanly separated.
    class CheckStubPdfExtractor
      include Parity::CanonicalSchema
      include PdfBoxText

      # Top-check default layout bounds (CheckGenerator: PAGE_WIDTH=612, SECTION_HEIGHT=264).
      CHECK_FACE_BOX = [ 0, 528, 612, 792 ].freeze
      STUB1_LEFT_BOX = [ 0, 264, 338, 528 ].freeze
      STUB1_RIGHT_BOX = [ 338, 264, 612, 528 ].freeze

      TWO_NUM_ROW = /\A(.+?)\s+(-?\$?[\d,]+\.\d{2})\s+(-?\$?[\d,]+\.\d{2})\z/
      PAY_ROW = /\A(.+?)\s+(-|-?[\d,]+\.\d{2})\s+(-|-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s+(-|-?[\d,]+\.\d{2})\z/

      def extract(pdf_bytes)
        reader = PDF::Reader.new(StringIO.new(pdf_bytes))
        page = reader.pages.first
        void_watermark = page.runs(merge: false).select { |run| run.font_size >= 20 }.map(&:text).join.include?("VOID")

        face_lines = text_in_box(page, CHECK_FACE_BOX).lines(chomp: true).map(&:strip).reject(&:empty?)
        left_lines = text_in_box(page, STUB1_LEFT_BOX).lines(chomp: true).map(&:strip).reject(&:empty?)
        right_lines = text_in_box(page, STUB1_RIGHT_BOX).lines(chomp: true).map(&:strip).reject(&:empty?)

        left = parse_left_column(left_lines)
        right = parse_right_column(right_lines)

        {
          employee_name: left[:employee_name],
          check_face_lines: face_lines,
          gross_pay: left[:gross_current] || right[:summary_current]["Total Pay"],
          net_pay: right[:net_pay],
          taxes: right[:tax_amounts],
          tax_labels: right[:tax_labels],
          deductions: right[:deductions],
          employer_contributions: left[:employer_contributions],
          other_pay: left[:other_pay],
          earnings: left[:earnings],
          hours: left[:hours],
          ytd: {
            gross: left[:gross_ytd] || right[:summary_ytd]["Total Pay"],
            income_tax: right[:tax_ytd][:income_tax],
            additional_withholding: right[:tax_ytd][:additional_withholding],
            total_income_tax: sum_present(right[:tax_ytd][:income_tax], right[:tax_ytd][:additional_withholding]),
            social_security: right[:tax_ytd][:social_security],
            medicare_total: right[:tax_ytd][:medicare_total],
            taxes_total: right[:summary_ytd]["Taxes"],
            deductions: right[:summary_ytd]["Deductions"],
            net: nil # Check stub PDF SUMMARY box prints current NET PAY only
          },
          dates: {
            period_start: left[:period_start],
            period_end: left[:period_end],
            pay_date: left[:pay_date]
          },
          status: {
            voided: void_watermark
          },
          raw_left: left_lines,
          raw_right: right_lines
        }
      end

      private

      def parse_left_column(lines)
        employee_name = lines.first unless lines.first&.start_with?("PAY ")
        section = nil
        earnings = []
        other_pay = {}
        employer_contributions = {}
        gross_current = nil
        gross_ytd = nil
        period_start = nil
        period_end = nil
        pay_date = nil
        expect_next = nil

        regular = money(0)
        overtime = money(0)
        pto = money(0)
        holiday = money(0)

        lines.each do |line|
          if expect_next == :pay_period && (m = line.match(/\A(\d{2}\/\d{2}\/\d{4})\s*-\s*(\d{2}\/\d{2}\/\d{4})\z/))
            period_start = iso_date(m[1])
            period_end = iso_date(m[2])
            expect_next = nil
            next
          elsif expect_next == :pay_date && (m = line.match(/\A(\d{2}\/\d{2}\/\d{4})\z/))
            pay_date = iso_date(m[1])
            expect_next = nil
            next
          end

          if line.start_with?("PAY ")
            section = :pay
          elsif line.start_with?("OTHER PAY")
            section = :other_pay
          elsif line == "Pay Period"
            section = :dates
            expect_next = :pay_period
          elsif line == "Pay Date"
            section = :dates
            expect_next = :pay_date
          elsif line.start_with?("MEMO:")
            section = :memo
          elsif section == :pay
            if (m = line.match(/\ATOTAL\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\z/))
              gross_current = money(m[1])
              gross_ytd = money(m[2])
            elsif (m = line.match(PAY_ROW))
              label = m[1].strip
              hrs = hours(m[2])
              earnings << {
                label: label,
                hours: hrs,
                rate: money(m[3]),
                amount: money(m[4]),
                ytd: money(m[5])
              }
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
          elsif section == :other_pay
            if (m = line.match(TWO_NUM_ROW))
              label = m[1].strip
              current = money(m[2])
              ytd = money(m[3])
              if label.start_with?("ER ")
                key = label.downcase.include?("401(k)") ? :employer_401k_match : label.downcase.gsub(/[^a-z0-9]+/, "_").to_sym
                employer_contributions[key] = { label: label, amount: current, ytd: ytd }
              else
                key = label.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
                other_pay[key] = { label: label, amount: current, ytd: ytd }
              end
            end
          end
        end

        {
          employee_name: employee_name,
          earnings: earnings,
          gross_current: gross_current,
          gross_ytd: gross_ytd,
          other_pay: other_pay,
          employer_contributions: employer_contributions,
          period_start: period_start,
          period_end: period_end,
          pay_date: pay_date,
          hours: {
            regular: regular,
            overtime: overtime,
            pto: pto,
            holiday: holiday,
            combined: (regular + overtime + pto + holiday).round(2)
          }
        }
      end

      def parse_right_column(lines)
        section = nil
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
        summary_current = {}
        summary_ytd = {}
        net_pay = nil

        lines.each do |line|
          if line.start_with?("TAXES ")
            section = :taxes
          elsif line.start_with?("DEDUCTIONS ")
            section = :deductions
          elsif line.start_with?("SUMMARY ")
            section = :summary
          elsif (m = line.match(/\ANET PAY:\s*(-?\$[\d,]+\.\d{2})\z/))
            net_pay = money(m[1])
          elsif section == :taxes
            next if line.start_with?("TOTAL ")
            next unless (m = line.match(TWO_NUM_ROW))

            label = m[1].strip
            current = money(m[2])
            ytd = money(m[3])
            down = label.downcase

            if down.include?("addtl w/h") || down.include?("w-4 4c") || down.include?("additional")
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
              tax_amounts[:medicare_total] = current
              tax_ytd[:medicare_total] = ytd
              tax_labels[:medicare] = label
            end
          elsif section == :deductions
            next if line.start_with?("TOTAL ")
            next unless (m = line.match(TWO_NUM_ROW))

            label = m[1].strip
            key = canonical_deduction_key(label)
            deductions[key] = { label: label, amount: money(m[2]), ytd: money(m[3]) }
          elsif section == :summary
            next unless (m = line.match(TWO_NUM_ROW))

            label = m[1].strip
            summary_current[label] = money(m[2])
            summary_ytd[label] = money(m[3])
          end
        end

        tax_amounts[:total_income_tax] = (tax_amounts[:income_tax] + tax_amounts[:additional_withholding]).round(2)
        tax_amounts[:total_taxes] = (tax_amounts[:total_income_tax] + tax_amounts[:social_security] + tax_amounts[:medicare_total]).round(2)

        {
          tax_amounts: tax_amounts,
          tax_ytd: tax_ytd,
          tax_labels: tax_labels,
          deductions: deductions,
          summary_current: summary_current,
          summary_ytd: summary_ytd,
          net_pay: net_pay
        }
      end

      def canonical_deduction_key(label)
        text = label.to_s.downcase
        return :retirement_401k if text.include?("401(k)") && !text.include?("roth")
        return :roth_401k if text.include?("roth")

        text.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
      end

      def sum_present(*values)
        present = values.compact
        return nil if present.empty?

        present.sum(0.to_d).round(2)
      end
    end
  end
end
