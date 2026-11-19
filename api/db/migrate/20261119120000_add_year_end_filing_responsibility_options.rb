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
    # The client and no-filing parties are year-end (W-2GU and 1099) answers only.
    add_check_constraint :payroll_filing_responsibilities,
                         <<~SQL.squish,
                           responsible_party IN ('external_provider', 'cornerstone')
                           OR
                           (responsible_party IN ('client', 'no_filing') AND filing_type IN ('w2_gu', 'form_1099'))
                         SQL
                         name: "payroll_filing_responsibilities_party_check"
    add_check_constraint :payroll_filing_responsibilities,
                         "prior_provider_through IS NULL OR (filing_type IN ('w2_gu', 'form_1099') AND responsible_party = 'cornerstone')",
                         name: "payroll_filing_responsibilities_prior_provider_check"
  end

  # The old constraints cannot hold 1099 decisions, client or no-filing
  # parties, or prior-provider dates. Refuse rather than delete them.
  #
  # Data-preserving rollback: roll back the application only and leave this
  # migration applied. The wider constraints still accept every value the
  # previous release writes. That release ignores form_1099 rows and the
  # prior-provider date, but it reads a w2_gu decision of "client" or
  # "no_filing" as Cornerstone-responsible (PayrollFilingResponsibilityGate
  # treats any party other than external_provider that way). Nothing is filed
  # automatically, but until the year-end release is restored, staff must not
  # prepare W-2GUs for those companies; list them with
  #   PayrollFilingResponsibility.where(filing_type: "w2_gu", responsible_party: %w[client no_filing])
  def down
    blocking = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM payroll_filing_responsibilities
      WHERE filing_type = 'form_1099' OR responsible_party IN ('client', 'no_filing') OR prior_provider_through IS NOT NULL
    SQL
    if blocking.positive?
      raise ActiveRecord::IrreversibleMigration,
            "#{blocking} payroll filing responsibility row(s) use year-end options (a 1099 decision, a client or no-filing party, " \
            "or a prior-provider date) that the previous constraints do not allow. Export and remove those rows before rolling back."
    end

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
