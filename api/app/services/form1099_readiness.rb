# frozen_string_literal: true

# E1 integration seam: replace this fail-closed adapter with fingerprint-bound
# 1099 readiness once E1 lands. Never infer 1099 readiness from W-2 readiness.
class Form1099Readiness
  def self.final?(company:, year:)
    false
  end
end
