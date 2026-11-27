# frozen_string_literal: true

class EmployeeDocument < ApplicationRecord
  belongs_to :company
  belongs_to :payroll_item, optional: true
  belongs_to :historical_paycheck, optional: true
  belongs_to :employee, optional: true
  belongs_to :replaces_document, class_name: "EmployeeDocument", optional: true
  belongs_to :withdrawn_by, class_name: "User", optional: true
  has_many :notices, class_name: "EmployeeDocumentNotice", dependent: :restrict_with_exception

  enum :status, { posted: "posted", replaced: "replaced", withdrawn: "withdrawn" }

  # A W-2GU copy (Copy B and C) posted for one employee and tax year (M4-5).
  scope :tax_forms, -> { where.not(tax_year: nil) }

  def self.posted_by_payroll_item(company_id, item_ids)
    posted.where(company_id: company_id, payroll_item_id: item_ids).order(revision: :asc).index_by(&:payroll_item_id)
  end

  def tax_form?
    tax_year.present?
  end

  # Older and structural corrections retain the link-based classification.
  def correction_label?
    correction_label.nil? ? corrected? : correction_label
  end

  def correction_revision?
    return corrected? if money_changed.nil?
    return true if money_changed?

    predecessor = replaces_document
    predecessor.present? && (predecessor.payroll_item_id != payroll_item_id ||
      predecessor.withdrawn? || predecessor.withdrawal_reason.present?)
  end

  attr_readonly :company_id, :payroll_item_id, :historical_paycheck_id, :employee_id, :tax_year,
    :revision, :storage_key, :sha256, :posted_at, :payment_line, :payroll_facts_sha256, :corrected, :replaces_document_id
end
