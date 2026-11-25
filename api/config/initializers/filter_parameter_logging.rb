# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# Taxpayer IDs are matched by exact name: a W-9's `tin` (the year-end
# checklist's "add as a new contractor") and a contractor's `contractor_ein`.
# A partial `:tin` would also hide unrelated keys such as "settings".
# The first pattern covers parsed parameters, whose keys are the leaf names.
# The second covers the query string in the request-start log line, which
# Rails filters key by key as written in the URL: bracketed
# (`payee[contractor][tin]`) or URL-encoded (`payee%5Bcontractor%5D%5Btin%5D`).
# Staff note bodies and hide reasons may accidentally contain rejected SSNs or
# account numbers. Filter nested note params (dot-joined paths for parsed JSON
# and form bodies, plus bracketed query-string keys) without hiding unrelated
# `body` or `reason` keys on other endpoints.
# Email recipients: `cc`, `bcc`, `recipients` and `reply_to` hold addresses
# wherever they appear. A bare `to` or `from` is a date range on report and
# list endpoints, so those are filtered only inside an email provider
# payload's `data` (Resend's webhook; that endpoint also masks its whole body).
#
# Personal details, compensation figures, emergency contacts, Form 500/941 tax
# figures, and tax IDs use exact leaf names (plus bracketed/URL-encoded
# query-string forms). Generic `name`, `rate`, and `amount` are path-scoped to
# PII/compensation containers so non-PII debugging values (`department.name`,
# `company.name`, `tax_config.rate`, `invoice.amount`, `company_name`,
# `department_name`, `settings`) stay readable in request logs.
SENSITIVE_EXACT_PARAM_NAMES = %w[
  tin contractor_ein ein company_ein employer_ein fein tax_id employer_identification_number
  phone mobile_phone work_phone home_phone contact_phone main_phone
  address address_line1 address_line2 street street_address mailing_address
  company_address company_address_line1 company_address_line2 company_city company_state company_zip
  city zip zip_code postal_code
  first_name middle_name last_name name_suffix full_name legal_name preferred_name
  employee_name payee_name contact_name filing_contact_name
  pay_rate hourly_rate salary base_salary annual_salary salary_override
  gross_pay adjusted_gross net_pay regular_pay overtime_pay holiday_pay pto_pay sick_pay
  bonus commission tips tip_amount reported_tips tips_paid_out service_charge_wages
  non_taxable_pay qualified_overtime_compensation
  reimbursement deduction_amount original_amount default_amount default_percentage payment_amount
  additional_withholding additional_withholding_override withholding
  withholding_tax_adjustment withholding_tax_override
  income_tax_withholding_on_wages tax_withholding_30_percent corporate_estimated_tax
  income_tax_withholding_1099 total_guam_withholding total_taxes_dollars total_taxes_cents
  pretax_deductions after_tax_deductions employee_taxes federal_income_tax
  social_security_tax medicare_tax employer_taxes employer_contributions total_payroll_cost
  line5a_ss_wages line5a_ss_combined_tax line5b_ss_tips line5b_ss_tips_combined_tax
  line5c_medicare_wages line5c_medicare_combined_tax line5d_add_medicare_wages
  line5d_add_medicare_tax line5e_total_ss_medicare line6_total_taxes_before_adj
  line7_adj_fractions_cents line10_total_taxes_after_adj line12_total_after_credits
  starting_balance opening_balance loan_amount wages ytd_gross ytd_net
  tax_amount allowances w4_dependent_credit w4_step4a_other_income w4_step4b_deductions
  retirement_rate roth_retirement_rate employer_retirement_match_rate employer_roth_match_rate
  traditional_rate traditional_amount roth_rate roth_amount eligible_compensation
  employer_match_rate employer_match_deferral_cap_rate employer_match_period_cap
  employer_match_annual_cap employer_match_ytd_before_system
  prior_year_fica_wages external_traditional_deferrals external_roth_deferrals
  eligible_compensation_before_system employer_additions_before_system non_roth_after_tax_before_system
  percentage
  relationship emergency_contact emergency_contacts emergency_contact_name
  emergency_contact_phone emergency_contact_relationship
  routing_number account_number bank_account bank_name bank_address iban
].freeze

SENSITIVE_NAME_PARENTS = %w[
  user emergency_contact emergency_contacts help_contacts entries actor
].freeze

SENSITIVE_RATE_PARENTS = %w[
  employee_wage_rate wage_rates wage_rate_hours compensation_wage_rate_edits
].freeze

SENSITIVE_AMOUNT_PARENTS = %w[
  custom_earnings custom_deductions payroll_adjustments payroll_field_entries
  default_custom_earnings default_payroll_adjustments employee_payroll_field
  daily_liabilities earnings_breakdown pretax_deduction_breakdown
  after_tax_deduction_breakdown employee_tax_breakdown employer_tax_breakdown
  employer_contribution_breakdown classifications
].freeze

SENSITIVE_EXACT_PARAM_PATTERN = /\A(?:#{SENSITIVE_EXACT_PARAM_NAMES.join('|')})\z/i
SENSITIVE_BRACKETED_PARAM_PATTERN = /(?:\[|%5B)(?:#{SENSITIVE_EXACT_PARAM_NAMES.join('|')})(?:\]|%5D)/i

# Path-scoped patterns contain `\.` so ActiveSupport::ParameterFilter matches
# them against the dot-joined key path (for parsed JSON/form bodies), while the
# bracketed siblings cover raw query strings in request-start logs.
# Top-level `name` is included via `\Aname\z` inside the dot-containing regex so
# flat emergency contact payloads (`POST /employee/profile/emergency_contacts`)
# are redacted without hiding nested `department.name` or `company.name`.
SCOPED_SENSITIVE_NAME_PATH_PATTERN = /(?:\Aname\z|(?:\A|\.)(?:#{SENSITIVE_NAME_PARENTS.join('|')})\.name\z)/i
SCOPED_SENSITIVE_NAME_QUERY_PATTERN = /(?:\A|\[|%5B)(?:#{SENSITIVE_NAME_PARENTS.join('|')})(?:\]|%5D)?(?:\[|%5B)name(?:\]|%5D)/i

SCOPED_SENSITIVE_RATE_PATH_PATTERN = /(?:\A|\.)(?:#{SENSITIVE_RATE_PARENTS.join('|')})\.rate\z/i
SCOPED_SENSITIVE_RATE_QUERY_PATTERN = /(?:\A|\[|%5B)(?:#{SENSITIVE_RATE_PARENTS.join('|')})(?:\]|%5D)?(?:\[|%5B)rate(?:\]|%5D)/i

SCOPED_SENSITIVE_AMOUNT_PATH_PATTERN = /(?:\A|\.)(?:#{SENSITIVE_AMOUNT_PARENTS.join('|')})\.amount\z/i
SCOPED_SENSITIVE_AMOUNT_QUERY_PATTERN = /(?:\A|\[|%5B)(?:#{SENSITIVE_AMOUNT_PARENTS.join('|')})(?:\]|%5D)?(?:\[|%5B)amount(?:\]|%5D)/i

Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :ticket, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :invite_nonce, :code, :state, :birth, :upload, /\Afiles?\z/i,
  SENSITIVE_EXACT_PARAM_PATTERN,
  SENSITIVE_BRACKETED_PARAM_PATTERN,
  SCOPED_SENSITIVE_NAME_PATH_PATTERN,
  SCOPED_SENSITIVE_NAME_QUERY_PATTERN,
  SCOPED_SENSITIVE_RATE_PATH_PATTERN,
  SCOPED_SENSITIVE_RATE_QUERY_PATTERN,
  SCOPED_SENSITIVE_AMOUNT_PATH_PATTERN,
  SCOPED_SENSITIVE_AMOUNT_QUERY_PATTERN,
  /(?:\A|\.)(?:employee_)?note\.(?:body|reason|hidden_reason)\z/i,
  /(?:\A|\[|%5B)(?:employee_)?note(?:\]|%5D)?(?:\[|%5B)(?:body|reason|hidden_reason)(?:\]|%5D)/i,
  /\A(?:cc|bcc|recipients|reply_to)\z/i,
  /(?:\A|\.)data\.(?:to|from|cc|bcc|recipients|reply_to)\z/i
]
