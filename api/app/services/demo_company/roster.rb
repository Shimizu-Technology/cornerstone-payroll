# frozen_string_literal: true

require "bigdecimal/util"

module DemoCompany
  # The fictional people and addresses of the two demo employers, shared by the
  # seed, the QuickBooks sample and the keyed rename service so the history,
  # the payroll and the pay stubs agree.
  #
  # People are numbered "Employee 01" through "Employee 11" across the 12
  # employment rows (Employee 06 works at both employers and keeps one number).
  # Streets are invented (no real Guam roads) with Guam-range ZIP codes.
  # SSNs use the 900 area, which the SSA never issues. Phones use 555-01xx,
  # which is reserved for fiction. Birth dates are fixed. Routing numbers fail
  # the ABA checksum, so no real account is ever stored.
  module Roster
    KITCHEN = "harbor-finch-kitchen"
    CATERING = "harbor-finch-catering"
    MARKET = "harbor-finch-market"

    CLIENT_MANAGER_LABEL = "Client Manager"
    CLIENT_USER_LABEL = "Client User"

    BANK_NAME = "Tasi Cove Savings"
    BANK_ADDRESS = "303 Tasi Cove Plaza, Hagåtña, GU 96910"

    KITCHEN_ADDRESS = {
      address_line1: "101 Harbor Finch Way",
      city: "Hagåtña",
      state: "GU",
      zip: "96910"
    }.freeze

    CATERING_ADDRESS = {
      address_line1: "202 Coral Lantern Lane",
      city: "Maite",
      state: "GU",
      zip: "96910"
    }.freeze

    MARKET_ADDRESS = {
      address_line1: "303 Market Lantern Way",
      city: "Tamuning",
      state: "GU",
      zip: "96913"
    }.freeze

    EMPLOYEE_STREET = "Finch Cove Lane"
    MARKET_EMPLOYEE_STREET = "Market Lantern Lane"
    EMPLOYEE_CITY = "Hagåtña"
    EMPLOYEE_STATE = "GU"
    EMPLOYEE_ZIP = "96910"

    # quickbooks: true people worked at the Kitchen January–July 2026 and come
    # in through its QuickBooks history; the rest start in native payroll.
    PEOPLE = [
      { key: "employee-01", number: 1, company: KITCHEN, first: "Employee", last: "01", dept: "Kitchen", type: "hourly", rate: "17.50".to_d,
        ssn: "900-01-1001", dob: Date.new(1994, 3, 14), phone: "(671) 555-0161", delivery: "direct_deposit",
        routing: "123456789", account: "4011001", hours: 80, overtime: [ 0, 6, 0, 4, 0, 8, 0, 3 ], quickbooks: true, hire_date: Date.new(2025, 9, 2) },
      { key: "employee-02", number: 2, company: KITCHEN, first: "Employee", last: "02", dept: "Front of house", type: "hourly", rate: "9.25".to_d,
        ssn: "900-01-1003", dob: Date.new(1998, 11, 2), phone: "(671) 555-0162", delivery: "paper_check", hours: 72,
        tips: %w[410.25 388.50 452.75 401.00 476.20 395.40 430.10 418.60].map(&:to_d), uniform_deduction: "15.00".to_d,
        quickbooks: true, hire_date: Date.new(2025, 6, 16) },
      { key: "employee-03", number: 3, company: KITCHEN, first: "Employee", last: "03", dept: "Front of house", type: "hourly", rate: "11.00".to_d,
        ssn: "900-01-1004", dob: Date.new(2003, 5, 27), phone: "(671) 555-0163", delivery: "paper_check", hours: 32,
        short_hours: { 2 => 12 }, quickbooks: true, hire_date: Date.new(2025, 11, 10) },
      { key: "employee-04", number: 4, company: KITCHEN, first: "Employee", last: "04", dept: "Kitchen", type: "hourly", rate: "13.75".to_d,
        ssn: "900-01-1005", dob: Date.new(1989, 8, 9), phone: "(671) 555-0164", delivery: "paper_check", hours: 80,
        terminate_after: 3, quickbooks: true, hire_date: Date.new(2024, 4, 1) },
      { key: "employee-05", number: 5, company: KITCHEN, first: "Employee", last: "05", dept: "Kitchen", type: "hourly", rate: "14.25".to_d,
        ssn: "900-01-1006", dob: Date.new(1996, 1, 30), phone: "(671) 555-0165", delivery: "direct_deposit",
        routing: "123456781", account: "4011006", hours: 80, terminate_after: 1, rehire_before: 4, quickbooks: true, hire_date: Date.new(2025, 2, 3) },
      { key: "employee-06-kitchen", number: 6, company: KITCHEN, first: "Employee", last: "06", dept: "Kitchen", type: "hourly", rate: "12.50".to_d,
        ssn: "900-01-1008", dob: Date.new(2000, 12, 12), phone: "(671) 555-0166", delivery: "paper_check", hours: 40,
        quickbooks: true, hire_date: Date.new(2025, 8, 18) },
      { key: "employee-07", number: 7, company: KITCHEN, first: "Employee", last: "07", dept: "Front of house", type: "hourly", rate: "10.50".to_d,
        ssn: "900-01-1009", dob: Date.new(2001, 7, 4), phone: "(671) 555-0167", delivery: "paper_check", hours: 64,
        quickbooks: true, hire_date: Date.new(2025, 10, 6) },
      { key: "employee-08", number: 8, company: KITCHEN, first: "Employee", last: "08", dept: "Kitchen", type: "hourly", rate: "15.00".to_d,
        ssn: "900-01-1010", dob: Date.new(1991, 7, 21), phone: "(671) 555-0168", delivery: "direct_deposit",
        routing: "123456782", account: "4011010", hours: 80, raise: { from_index: 4, rate: "16.25".to_d }, quickbooks: true,
        hire_date: Date.new(2023, 3, 13) },
      { key: "employee-09", number: 9, company: KITCHEN, first: "Employee", last: "09", dept: "Office", type: "salary", rate: "52000".to_d,
        ssn: "900-01-1002", dob: Date.new(1985, 2, 18), phone: "(671) 555-0169", delivery: "direct_deposit",
        routing: "987654321", account: "4011002", hire_date: Date.new(2026, 7, 13) },
      { key: "employee-10", number: 10, company: KITCHEN, first: "Employee", last: "10", dept: "Office", type: "salary", rate: "68000".to_d,
        ssn: "900-01-1007", dob: Date.new(1982, 10, 5), phone: "(671) 555-0170", delivery: "direct_deposit",
        routing: "987654322", account: "4011007", hire_date: Date.new(2026, 7, 13) },
      { key: "employee-06-catering", number: 6, company: CATERING, first: "Employee", last: "06", dept: "Events", type: "hourly", rate: "13.00".to_d,
        ssn: "900-01-1008", dob: Date.new(2000, 12, 12), phone: "(671) 555-0166", delivery: "paper_check", hours: 24,
        hire_date: Date.new(2026, 7, 13) },
      { key: "employee-11", number: 11, company: CATERING, first: "Employee", last: "11", dept: "Events", type: "hourly", rate: "14.00".to_d,
        ssn: "900-01-1011", dob: Date.new(1993, 4, 22), phone: "(671) 555-0171", delivery: "paper_check", hours: 48,
        hire_date: Date.new(2026, 7, 13) }
    ].freeze

    # Synthetic client-managed employee lifecycle showcase roster for Harbor
    # Finch Market. Kept separate from PEOPLE so the Kitchen/Catering history,
    # QuickBooks sample, and rename fixture stay unchanged.
    LIFECYCLE_PEOPLE = [
      { key: "lifecycle-incomplete", number: 1, company: MARKET, first: "Jordan", last: "Sample", dept: "Retail",
        type: "hourly", rate: "16.50".to_d, ssn: "900-02-2001", dob: Date.new(1996, 4, 12), phone: "(671) 555-0181",
        delivery: "paper_check", hire_date: Date.new(2026, 11, 2), scenario: :incomplete_new_hire },
      { key: "lifecycle-ready", number: 2, company: MARKET, first: "Morgan", last: "Example", dept: "Retail",
        type: "hourly", rate: "18.00".to_d, ssn: "900-02-2002", dob: Date.new(1993, 9, 8), phone: "(671) 555-0182",
        delivery: "paper_check", hire_date: Date.new(2026, 11, 2), scenario: :ready_new_hire },
      { key: "lifecycle-pay-change", number: 3, company: MARKET, first: "Casey", last: "Fixture", dept: "Operations",
        type: "hourly", rate: "17.00".to_d, new_rate: "18.75".to_d, ssn: "900-02-2003", dob: Date.new(1990, 2, 19),
        phone: "(671) 555-0183", delivery: "paper_check", hire_date: Date.new(2026, 8, 3), scenario: :pay_change },
      { key: "lifecycle-w4-change", number: 4, company: MARKET, first: "Taylor", last: "Sample", dept: "Operations",
        type: "hourly", rate: "15.50".to_d, ssn: "900-02-2004", dob: Date.new(1995, 7, 25), phone: "(671) 555-0184",
        delivery: "paper_check", hire_date: Date.new(2026, 8, 3), scenario: :w4_change },
      { key: "lifecycle-dd-missing-bank", number: 5, company: MARKET, first: "Avery", last: "Example", dept: "Office",
        type: "hourly", rate: "19.00".to_d, ssn: "900-02-2005", dob: Date.new(1992, 12, 3), phone: "(671) 555-0185",
        delivery: "direct_deposit", hire_date: Date.new(2026, 8, 3), scenario: :direct_deposit_missing_bank },
      { key: "lifecycle-returned", number: 6, company: MARKET, first: "Riley", last: "Fixture", dept: "Retail",
        type: "hourly", rate: "16.00".to_d, ssn: "900-02-2006", dob: Date.new(1997, 6, 14), phone: "(671) 555-0186",
        delivery: "paper_check", hire_date: Date.new(2026, 8, 3), scenario: :returned_to_client },
      { key: "lifecycle-terminated", number: 7, company: MARKET, first: "Jamie", last: "Sample", dept: "Operations",
        type: "hourly", rate: "15.75".to_d, ssn: "900-02-2007", dob: Date.new(1991, 10, 29), phone: "(671) 555-0187",
        delivery: "paper_check", hire_date: Date.new(2026, 8, 3), scenario: :termination },
      { key: "lifecycle-rehired", number: 8, company: MARKET, first: "Quinn", last: "Example", dept: "Retail",
        type: "hourly", rate: "17.25".to_d, ssn: "900-02-2008", dob: Date.new(1994, 1, 17), phone: "(671) 555-0188",
        delivery: "paper_check", hire_date: Date.new(2026, 7, 13), scenario: :rehire },
      { key: "lifecycle-possible-self", number: 9, company: MARKET, first: "Sloane", last: "Fixture", dept: "Office",
        type: "hourly", rate: "20.00".to_d, ssn: "900-02-2009", dob: Date.new(1988, 5, 11), phone: "(671) 555-0189",
        delivery: "paper_check", hire_date: Date.new(2026, 8, 3), scenario: :possible_self_action },
      { key: "lifecycle-override", number: 10, company: MARKET, first: "Parker", last: "Sample", dept: "Retail",
        type: "hourly", rate: "16.00".to_d, ssn: "900-02-2010", dob: Date.new(1998, 8, 21), phone: "(671) 555-0190",
        delivery: "paper_check", hire_date: Date.new(2026, 11, 2), scenario: :readiness_override },
      { key: "lifecycle-grandfathered", number: 11, company: MARKET, first: "Drew", last: "Example", dept: "Operations",
        type: "hourly", rate: "18.50".to_d, ssn: "900-02-2011", dob: nil, phone: "(671) 555-0191",
        delivery: nil, hire_date: Date.new(2026, 7, 13), scenario: :grandfathered_missing_items }
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

    def lifecycle_people = LIFECYCLE_PEOPLE

    def quickbooks_people = PEOPLE.select { |person| person[:quickbooks] }

    def full_name(person) = "#{person[:first]} #{person[:last]}"

    def quickbooks_name(person) = "#{person[:last]}, #{person[:first]}"

    def ssn_digits(person) = person[:ssn].delete("-")

    def ssn_variants(person) = [ person[:ssn], ssn_digits(person) ]

    def address_line1_for(person) = "#{100 + person[:number]} #{EMPLOYEE_STREET}"

    def lifecycle_address_line1_for(person) = "#{200 + person[:number]} #{MARKET_EMPLOYEE_STREET}"

    def formatted_address(address) = "#{address[:address_line1]}, #{address[:city]}, #{address[:state]} #{address[:zip]}"

    def find_person(company_key, key: nil, ssn_digits: nil)
      candidates = people_for(company_key)
      return candidates.find { |person| person[:key] == key.to_s } if key.present?
      return nil if ssn_digits.blank?

      normalized = ssn_digits.to_s.gsub(/\D/, "")
      candidates.find { |person| self.ssn_digits(person) == normalized }
    end

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
