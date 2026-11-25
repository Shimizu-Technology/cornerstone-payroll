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
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :ticket, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :invite_nonce, :code, :state, :birth, :upload, /\Afiles?\z/i, /\A(tin|contractor_ein)\z/i,
  /(?:\[|%5B)(?:tin|contractor_ein)(?:\]|%5D)/i,
  /(?:\A|\.)(?:employee_)?note\.(?:body|reason|hidden_reason)\z/i,
  /(?:\A|\[|%5B)(?:employee_)?note(?:\]|%5D)?(?:\[|%5B)(?:body|reason|hidden_reason)(?:\]|%5D)/i,
  /\A(?:cc|bcc|recipients|reply_to)\z/i,
  /(?:\A|\.)data\.(?:to|from|cc|bcc|recipients|reply_to)\z/i
]
