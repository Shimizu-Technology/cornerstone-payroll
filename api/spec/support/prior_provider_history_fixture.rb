# frozen_string_literal: true

module PriorProviderHistoryFixture
  def history_fixture(period_count: 20)
    company = create(:company, historical_payroll_enabled: true, name: "Kasperbauer-shaped local fixture", pay_frequency: "semimonthly", next_check_number: 701)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    employees = 3.times.map { |i| create(:employee, :salary, company: company, first_name: "Employee", last_name: "#{i + 1}", pay_rate: 48_000, pay_frequency: "semimonthly", payment_delivery_method: "paper_check") }
    create(:tax_table, tax_year: 2026, pay_frequency: "semimonthly", ss_wage_base: 184_500) unless TaxTable.for_year(2026).exists?
    runs = (1..10).flat_map { |month| [ Date.new(2026, month, month == 10 ? 7 : 14), Date.new(2026, month, 28) ] }.first(period_count).map do |pay_date|
      run = create(:pay_period, :calculated, company: company, start_date: pay_date - 13, end_date: pay_date - 1, pay_date: pay_date)
      employees.each do |employee|
        create(:payroll_item, :salary, company: company, employee: employee, pay_period: run, pay_rate: 48_000,
          gross_pay: 2_000, withholding_tax: 200, social_security_tax: 124, medicare_tax: 29,
          employer_social_security_tax: 124, employer_medicare_tax: 29, net_pay: 1_647, total_deductions: 353,
          fit_taxable_wages: 2_000, social_security_taxable_wages: 2_000, social_security_taxable_tips: 0,
          medicare_taxable_wages: 2_000, additional_medicare_taxable_wages: 0, tax_rule_snapshot: {})
      end
      run
    end
    periods = runs.map do |run|
      period = PriorProviderHistory::SourceAdapter.candidate(run)
      period["register_totals"] = period.fetch("calculated_totals").slice(*PriorProviderHistory::Amounts::REGISTER_FIELDS)
      period["source_reference"] = "Paid provider register #{run.pay_date}, page 1"
      period
    end
    payload = {
      "tax_year" => 2026, "takeover_on" => "2026-11-01", "provider_name" => "Previous Payroll Provider",
      "same_employer_confirmed" => true, "complete_history_confirmed" => true,
      "periods" => periods,
      "identities" => employees.to_h { |employee| [ employee.id.to_s, { "source_name" => employee.full_name, "ssn_last4" => employee.ssn_last_four } ] }
    }
    [ company, actor, employees, runs, payload ]
  end

  def history_upload
    @prior_provider_register ||= Tempfile.new([ "synthetic-paid-register", ".csv" ])
    @prior_provider_register.write("Synthetic local provider evidence only\ngross,fit,ss,medicare,net\n6000,600,372,87,4941\n")
    @prior_provider_register.flush
    Rack::Test::UploadedFile.new(@prior_provider_register.path, "text/csv")
  end

  def convert_history(company, actor, payload, key: SecureRandom.uuid)
    plan = PriorProviderHistory::Plan.new(company: company, payload: payload).call
    raise plan.errors.join("; ") unless plan.ready?
    PriorProviderHistory::Conversion.new(company: company, actor: actor, payload: payload,
      preview_digest: plan.digest, idempotency_key: key, files: [ history_upload ],
      acknowledgement: PriorProviderHistory::Conversion::ACKNOWLEDGEMENT).call
  end

  def activate_history(onboarding, actor)
    PriorProviderHistory::Activation.new(onboarding: onboarding, actor: actor, acknowledgement: PriorProviderHistory::Activation::ACKNOWLEDGEMENT).call
  end

  def reverse_history(onboarding, actor)
    PriorProviderHistory::Reversal.new(onboarding: onboarding, actor: actor, reason: "Correct source register evidence", acknowledgement: PriorProviderHistory::Reversal::ACKNOWLEDGEMENT).call
  end
end

RSpec.configure do |config|
  config.include PriorProviderHistoryFixture
  config.after do
    @prior_provider_register&.close!
  end
end
