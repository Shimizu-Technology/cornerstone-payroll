# frozen_string_literal: true

class CompanyYtdTotal < ApplicationRecord
  belongs_to :company

  validates :year, presence: true
  validates :year, uniqueness: { scope: :company_id }

  # Reset all totals to zero
  def reset!
    update!(
      gross_pay: 0,
      net_pay: 0,
      withholding_tax: 0,
      social_security_tax: 0,
      medicare_tax: 0,
      employer_social_security: 0,
      employer_medicare: 0,
      total_employees: 0,
      active_employees: 0
    )
  end

  # Update totals from a payroll item
  def add_payroll_item!(payroll_item)
    with_lock do
      self.gross_pay += payroll_item.gross_pay.to_f
      self.net_pay += payroll_item.net_pay.to_f
      self.withholding_tax += payroll_item.withholding_tax.to_f
      self.social_security_tax += payroll_item.social_security_tax.to_f
      self.medicare_tax += payroll_item.medicare_tax.to_f
      # Employer match for SS and Medicare
      self.employer_social_security += payroll_item.employer_social_security_tax.to_f
      self.employer_medicare += payroll_item.employer_medicare_tax.to_f
      save!
    end
  end
end
