# frozen_string_literal: true

# Describe saved report values without inferring historical terms from a current profile.
class PayrollRateBasis
  def self.describe(employee)
    return "Source rate unavailable" if employee[:pay_rate].nil?

    case employee[:employment_type].to_s
    when "contractor"
      case employee[:contractor_pay_type].to_s
      when "flat_fee" then "USD/flat fee"
      when "hourly" then "USD/hour (primary rate; see Earnings Detail for all rates)"
      else "USD (contractor rate basis not recorded)"
      end
    when "salary"
      { "annual" => "USD/year (annual salary)", "per_period" => "USD/pay period", "variable" => "USD/pay period (variable salary)" }
        .fetch(employee[:salary_type].to_s, "USD (salary basis not recorded)")
    else
      "USD/hour (primary rate; see Earnings Detail for all rates)"
    end
  end
end
