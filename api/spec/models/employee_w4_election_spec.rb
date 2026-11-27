# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeW4Election do
  describe "effective date relative to signature date" do
    let(:employee) { build(:employee) }
    let(:election) do
      described_class.new(
        described_class::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
          company: employee.company, employee: employee, source: source, reason: "Recorded W-4",
          effective_on: Date.new(2026, 1, 1), w4_signed_on: Date.new(2026, 1, 2)
        )
      )
    end

    %w[employee_creation client_approved client_direct staff].each do |source_name|
      context "with source #{source_name}" do
        let(:source) { source_name }

        it "rejects an effective date before the signature" do
          expect(election).not_to be_valid
          expect(election.errors[:w4_effective_on]).to include(
            "Set the effective date on or after the date the W-4 was signed."
          )
        end
      end
    end

    %w[quickbooks_history legacy_profile].each do |source_name|
      context "with source #{source_name}" do
        let(:source) { source_name }

        it "allows an effective date before the signature" do
          expect(election).to be_valid
        end
      end
    end
  end
end
