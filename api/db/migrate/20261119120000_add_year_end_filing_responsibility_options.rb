# frozen_string_literal: true

# Year-end setup records who files a client's W-2GUs and 1099s: Cornerstone
# (optionally after a prior provider for part of the year), the client,
# another provider, or nobody because the record files no forms this year.
class AddYearEndFilingResponsibilityOptions < ActiveRecord::Migration[8.1]
  def up
    add_column :payroll_filing_responsibilities, :prior_provider_through, :date

    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_type_check"
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_period_check"
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_party_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "filing_type IN ('form_941', 'guam_withholding', 'swica', 'w2_gu', 'form_1099')",
                         name: "payroll_filing_responsibilities_type_check"
    add_check_constraint :payroll_filing_responsibilities,
                         <<~SQL.squish,
                           (filing_type IN ('w2_gu', 'form_1099') AND quarter IS NULL)
                           OR
                           (filing_type IN ('form_941', 'guam_withholding', 'swica') AND quarter BETWEEN 1 AND 4)
                         SQL
                         name: "payroll_filing_responsibilities_period_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "responsible_party IN ('external_provider', 'cornerstone', 'client', 'no_filing')",
                         name: "payroll_filing_responsibilities_party_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "prior_provider_through IS NULL OR (filing_type IN ('w2_gu', 'form_1099') AND responsible_party = 'cornerstone')",
                         name: "payroll_filing_responsibilities_prior_provider_check"
  end

  def down
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_prior_provider_check"
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_party_check"
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_period_check"
    remove_check_constraint :payroll_filing_responsibilities, name: "payroll_filing_responsibilities_type_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "filing_type IN ('form_941', 'guam_withholding', 'swica', 'w2_gu')",
                         name: "payroll_filing_responsibilities_type_check"
    add_check_constraint :payroll_filing_responsibilities,
                         <<~SQL.squish,
                           (filing_type = 'w2_gu' AND quarter IS NULL)
                           OR
                           (filing_type IN ('form_941', 'guam_withholding', 'swica') AND quarter BETWEEN 1 AND 4)
                         SQL
                         name: "payroll_filing_responsibilities_period_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "responsible_party IN ('external_provider', 'cornerstone')",
                         name: "payroll_filing_responsibilities_party_check"
    remove_column :payroll_filing_responsibilities, :prior_provider_through
  end
end
