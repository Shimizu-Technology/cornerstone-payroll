# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# Taxpayer IDs are matched by exact name: a W-9's `tin` (the year-end
# checklist's "add as a new contractor") and a contractor's `contractor_ein`.
# A partial `:tin` would also hide unrelated keys such as "settings".
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :ticket, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :code, :state, :upload, /\Afiles?\z/i, /\A(tin|contractor_ein)\z/i
]
