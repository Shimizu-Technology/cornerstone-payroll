# frozen_string_literal: true

module TaxWorkHours
  # A failure that is shown to the person who asked for the refresh. `code`
  # is stable for the UI; `message` is plain language and never includes the
  # secret, a signature, or a response body.
  class Error < StandardError
    MESSAGES = {
      "not_connected" => "Cornerstone Tax isn't connected yet. Set CORNERSTONE_TAX_API_URL and PAYROLL_WORK_HOURS_SECRET on Payroll's server.",
      "unauthorized" => "Cornerstone Tax didn't accept Payroll's signature. Check that PAYROLL_WORK_HOURS_SECRET is the same on both apps and that both servers' clocks are right.",
      "tax_not_configured" => "Cornerstone Tax isn't sharing hours yet: PAYROLL_WORK_HOURS_SECRET isn't set on the Tax server.",
      "invalid_request" => "Cornerstone Tax couldn't read the date range Payroll asked for.",
      "network" => "Payroll couldn't reach Cornerstone Tax. Check the address and try again in a few minutes.",
      "server_error" => "Cornerstone Tax had a problem answering. Try again in a few minutes.",
      "bad_response" => "Cornerstone Tax sent hours in a format Payroll doesn't understand. Nothing was changed."
    }.freeze

    attr_reader :code

    def initialize(code, detail = nil)
      @code = code
      message = MESSAGES.fetch(code)
      super(detail.present? ? "#{message} (#{detail})" : message)
    end
  end
end
