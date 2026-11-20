# frozen_string_literal: true

# The rule the final 1099 e-file and 1096 use: the client's "1099s ready"
# sign-off matches the current inputs (Form1099NecFilingState, which the
# official copies and the checklist read too), so all final 1099 output
# shares one sign-off. Read uncached: callers recheck it after generating a
# file in the same request, and the query cache would replay the first read.
class Form1099Readiness
  def self.final?(company:, year:)
    ActiveRecord::Base.uncached { Form1099NecFilingState.call(company: company, year: year).final }
  end
end
