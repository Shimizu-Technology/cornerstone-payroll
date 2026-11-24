# frozen_string_literal: true

class EmployeeDocument < ApplicationRecord
  belongs_to :company
  belongs_to :payroll_item, optional: true
  belongs_to :historical_paycheck, optional: true
  belongs_to :employee, optional: true
  belongs_to :replaces_document, class_name: "EmployeeDocument", optional: true

  enum :status, { posted: "posted", replaced: "replaced", withdrawn: "withdrawn" }

  attr_readonly :company_id, :payroll_item_id, :historical_paycheck_id, :employee_id, :tax_year,
    :revision, :storage_key, :sha256, :posted_at, :payment_line, :corrected, :replaces_document_id
end
