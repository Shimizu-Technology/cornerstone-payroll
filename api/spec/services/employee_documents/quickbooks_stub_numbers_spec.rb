# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocuments::QuickbooksStubNumbers do
  it "ignores labeled bank and check numbers and decimal amounts" do
    [
      "Routing 121000358", "Account number: 123-45-6789", "Check #523 05/2026",
      "Amount $1,234,567.89", "812.50 1234"
    ].each { |text| expect(described_class.possible_ssn?(text)).to be(false), text }
  end

  it "recognizes possible SSNs after normalizing separators" do
    [ "123 / 45 / 6789", "1-2-3-4-5-6-7-8-9", "123  45  6789", "123__45__6789", "123.45.6789", "123::45@6789",
      "SSN: 123 45 6789", "1 2 3 - 4 5 - 6 7 8 9", "123456789" ].each do |text|
      expect(described_class.possible_ssn?(text)).to be(true), text
    end
  end

  it "finds nine digits in any window of whole groups" do
    [ "123-45-6789 40", "12-34-56789", "SSN: 12-34-56789", "123 45 6789 12",
      "123-45-6789  7", "40 12-34-56789 8", "812 50 1234" ].each do |text|
      expect(described_class.possible_ssn?(text)).to be(true), text
    end
  end

  it "does not take part of a digit group to reach nine digits" do
    [ "1234567890", "123-45-67890" ].each { |text| expect(described_class.possible_ssn?(text)).to be(false), text }
  end

  it "recognizes an employee's own SSN even under an exempt label" do
    expect(described_class.employee_ssn?("Routing 123 / 45 / 6789", "123456789")).to be(true)
  end
end
