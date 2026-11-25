# frozen_string_literal: true

require "bigdecimal/util"

module DemoCompany
  # The fictional people of the two demo employers, shared by the seed and the
  # QuickBooks sample so the history, the payroll and the pay stubs agree.
  #
  # SSNs use the 900 area, which the SSA never issues. Phones use 555-01xx,
  # which is reserved for fiction. Birth dates are fixed. Routing numbers fail
  # the ABA checksum, so no real account is ever stored.
  module Roster
    KITCHEN = "harbor-finch-kitchen"
    CATERING = "harbor-finch-catering"

    # quickbooks: true people worked at the Kitchen January–July 2026 and come
    # in through its QuickBooks history; the rest start in native payroll.
    PEOPLE = [
      { key: "robin-lantern", company: KITCHEN, first: "Robin", last: "Lantern", dept: "Kitchen", type: "hourly", rate: "17.50".to_d,
        ssn: "900-01-1001", dob: Date.new(1994, 3, 14), phone: "(671) 555-0161", delivery: "direct_deposit",
        routing: "123456789", account: "4011001", hours: 80, overtime: [ 0, 6, 0, 4, 0, 8, 0, 3 ], quickbooks: true, hire_date: Date.new(2025, 9, 2) },
      { key: "rowan-drift", company: KITCHEN, first: "Rowan", last: "Drift", dept: "Front of house", type: "hourly", rate: "9.25".to_d,
        ssn: "900-01-1003", dob: Date.new(1998, 11, 2), phone: "(671) 555-0162", delivery: "paper_check", hours: 72,
        tips: %w[410.25 388.50 452.75 401.00 476.20 395.40 430.10 418.60].map(&:to_d), uniform_deduction: "15.00".to_d,
        quickbooks: true, hire_date: Date.new(2025, 6, 16) },
      { key: "avery-sprig", company: KITCHEN, first: "Avery", last: "Sprig", dept: "Front of house", type: "hourly", rate: "11.00".to_d,
        ssn: "900-01-1004", dob: Date.new(2003, 5, 27), phone: "(671) 555-0163", delivery: "paper_check", hours: 32,
        short_hours: { 2 => 12 }, quickbooks: true, hire_date: Date.new(2025, 11, 10) },
      { key: "jules-reed", company: KITCHEN, first: "Jules", last: "Reed", dept: "Kitchen", type: "hourly", rate: "13.75".to_d,
        ssn: "900-01-1005", dob: Date.new(1989, 8, 9), phone: "(671) 555-0164", delivery: "paper_check", hours: 80,
        terminate_after: 3, quickbooks: true, hire_date: Date.new(2024, 4, 1) },
      { key: "quinn-sable", company: KITCHEN, first: "Quinn", last: "Sable", dept: "Kitchen", type: "hourly", rate: "14.25".to_d,
        ssn: "900-01-1006", dob: Date.new(1996, 1, 30), phone: "(671) 555-0165", delivery: "direct_deposit",
        routing: "123456781", account: "4011006", hours: 80, terminate_after: 1, rehire_before: 4, quickbooks: true, hire_date: Date.new(2025, 2, 3) },
      { key: "kit-wren-kitchen", company: KITCHEN, first: "Kit", last: "Wren", dept: "Kitchen", type: "hourly", rate: "12.50".to_d,
        ssn: "900-01-1008", dob: Date.new(2000, 12, 12), phone: "(671) 555-0166", delivery: "paper_check", hours: 40,
        quickbooks: true, hire_date: Date.new(2025, 8, 18) },
      { key: "sky-lark", company: KITCHEN, first: "Sky", last: "Lark", dept: "Front of house", type: "hourly", rate: "10.50".to_d,
        ssn: "900-01-1009", dob: Date.new(2001, 7, 4), phone: "(671) 555-0167", delivery: "paper_check", hours: 64,
        quickbooks: true, hire_date: Date.new(2025, 10, 6) },
      { key: "drew-flint", company: KITCHEN, first: "Drew", last: "Flint", dept: "Kitchen", type: "hourly", rate: "15.00".to_d,
        ssn: "900-01-1010", dob: Date.new(1991, 7, 21), phone: "(671) 555-0168", delivery: "direct_deposit",
        routing: "123456782", account: "4011010", hours: 80, raise: { from_index: 4, rate: "16.25".to_d }, quickbooks: true,
        hire_date: Date.new(2023, 3, 13) },
      { key: "ellis-quill", company: KITCHEN, first: "Ellis", last: "Quill", dept: "Office", type: "salary", rate: "52000".to_d,
        ssn: "900-01-1002", dob: Date.new(1985, 2, 18), phone: "(671) 555-0169", delivery: "direct_deposit",
        routing: "987654321", account: "4011002", hire_date: Date.new(2026, 7, 13) },
      { key: "maren-fable", company: KITCHEN, first: "Maren", last: "Fable", dept: "Office", type: "salary", rate: "68000".to_d,
        ssn: "900-01-1007", dob: Date.new(1982, 10, 5), phone: "(671) 555-0170", delivery: "direct_deposit",
        routing: "987654322", account: "4011007", hire_date: Date.new(2026, 7, 13) },
      { key: "kit-wren-catering", company: CATERING, first: "Kit", last: "Wren", dept: "Events", type: "hourly", rate: "13.00".to_d,
        ssn: "900-01-1008", dob: Date.new(2000, 12, 12), phone: "(671) 555-0166", delivery: "paper_check", hours: 24,
        hire_date: Date.new(2026, 7, 13) },
      { key: "morgan-tide", company: CATERING, first: "Morgan", last: "Tide", dept: "Events", type: "hourly", rate: "14.00".to_d,
        ssn: "900-01-1011", dob: Date.new(1993, 4, 22), phone: "(671) 555-0171", delivery: "paper_check", hours: 48,
        hire_date: Date.new(2026, 7, 13) }
    ].freeze

    # Biweekly calendar shared by both: periods start on Sundays, paid the
    # Friday after they end. QuickBooks covers the 14 Kitchen paydays from
    # January 23 to July 24; native payroll starts with the August 7 payday.
    CALENDAR_ANCHOR = Date.new(2026, 1, 4)
    # QuickBooks-era withholding factors. Money stays BigDecimal throughout
    # and becomes a float or string only when written to a file.
    FIT_RATE = "0.08".to_d
    SOCIAL_SECURITY_RATE = "0.062".to_d
    MEDICARE_RATE = "0.0145".to_d
    QUICKBOOKS_PERIODS = 14
    NATIVE_COMMITTED_PERIODS = 8

    module_function

    def people_for(company_key) = PEOPLE.select { |person| person[:company] == company_key }

    def quickbooks_people = PEOPLE.select { |person| person[:quickbooks] }

    def period(index)
      start = CALENDAR_ANCHOR + (14 * index)
      { start_date: start, end_date: start + 13, pay_date: start + 19 }
    end

    def quickbooks_periods = (0...QUICKBOOKS_PERIODS).map { |index| period(index).merge(index: index) }

    # Native periods are indexed from 0 (the August 7 payday); the last one is
    # left open in draft.
    def native_periods
      (0..NATIVE_COMMITTED_PERIODS).map do |index|
        period(QUICKBOOKS_PERIODS + index).merge(index: index, open: index == NATIVE_COMMITTED_PERIODS)
      end
    end

    # One QuickBooks paycheck: regular hours only, with withholding derived
    # from gross so every report and stub agrees to the cent.
    def quickbooks_paycheck(person, period)
      hours = person.fetch(:hours)
      gross = (hours * person.fetch(:rate)).round(2)
      fit = (gross * FIT_RATE).round(2)
      ss = (gross * SOCIAL_SECURITY_RATE).round(2)
      med = (gross * MEDICARE_RATE).round(2)
      { hours: hours, gross: gross, fit: fit, ss: ss, med: med, net: (gross - fit - ss - med).round(2) }.merge(period)
    end
  end
end
