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
# Personal details, compensation figures, emergency contacts, and tax IDs use
# exact leaf names (plus bracketed/URL-encoded query-string forms) so harmless
# fields such as `company_name`, `department_name`, `file_name`, or `settings`
# remain readable in request logs.
SENSITIVE_EXACT_PARAM_NAMES = %w[
  tin contractor_ein ein company_ein employer_ein fein tax_id
  phone mobile_phone work_phone home_phone contact_phone main_phone
  address address_line1 address_line2 street street_address mailing_address
  city zip zip_code postal_code
  name first_name middle_name last_name full_name legal_name preferred_name
  employee_name payee_name contact_name filing_contact_name
  pay_rate hourly_rate salary base_salary annual_salary rate amount
  gross_pay net_pay regular_pay overtime_pay holiday_pay pto_pay sick_pay
  bonus commission tips tip_amount reimbursement deduction_amount
  additional_withholding withholding default_amount payment_amount
  starting_balance opening_balance loan_amount wages ytd_gross ytd_net
  tax_amount allowances w4_dependent_credit w4_step4a_other_income
  w4_step4b_deductions retirement_rate roth_retirement_rate percentage
  emergency_contact emergency_contacts emergency_contact_name
  emergency_contact_phone emergency_contact_relationship
  routing_number account_number bank_account iban
].freeze

SENSITIVE_EXACT_PARAM_PATTERN = /\A(?:#{SENSITIVE_EXACT_PARAM_NAMES.join('|')})\z/i
SENSITIVE_BRACKETED_PARAM_PATTERN = /(?:\[|%5B)(?:#{SENSITIVE_EXACT_PARAM_NAMES.join('|')})(?:\]|%5D)/i

Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :ticket, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :invite_nonce, :code, :state, :birth, :upload, /\Afiles?\z/i,
  SENSITIVE_EXACT_PARAM_PATTERN,
  SENSITIVE_BRACKETED_PARAM_PATTERN,
  /(?:\A|\.)(?:employee_)?note\.(?:body|reason|hidden_reason)\z/i,
  /(?:\A|\[|%5B)(?:employee_)?note(?:\]|%5D)?(?:\[|%5B)(?:body|reason|hidden_reason)(?:\]|%5D)/i,
  /\A(?:cc|bcc|recipients|reply_to)\z/i,
  /(?:\A|\.)data\.(?:to|from|cc|bcc|recipients|reply_to)\z/i
]
