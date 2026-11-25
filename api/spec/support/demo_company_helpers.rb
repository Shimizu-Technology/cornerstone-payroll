# frozen_string_literal: true

module DemoCompanyHelpers
  def create_demo_company(organization:, name: "Harbor Finch Kitchen", fixture_key: "harbor-finch-kitchen", **attributes)
    create(
      :company,
      organization: organization,
      name: name,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "demo",
      migration_rehearsal_status: "ready",
      test_workspace_manifest: { "version" => 1, "purpose" => "demo", "demo_fixture_key" => fixture_key },
      auto_create_fit_check: false,
      **attributes
    )
  end

  # The contained demo commit path is not built yet, so fixtures mark a demo
  # pay period committed directly, as that path will.
  def create_committed_demo_pay_period(company:, pay_date:, employee:, gross_pay: 2_000)
    period = create(:pay_period, company: company, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    period.update_columns(status: "committed", committed_at: Time.current)
    create(:payroll_item,
      company: company, employee: employee, pay_period: period,
      gross_pay: gross_pay, net_pay: gross_pay.to_d * "0.8".to_d, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124,
      medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: gross_pay, social_security_taxable_tips: 0, medicare_taxable_wages: gross_pay,
      fit_taxable_wages: gross_pay)
    period.reload
  end
end

RSpec.configure { |config| config.include DemoCompanyHelpers }
