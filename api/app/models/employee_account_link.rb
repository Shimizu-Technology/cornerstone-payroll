# frozen_string_literal: true

class EmployeeAccountLink < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company
  belongs_to :employee
  belongs_to :invited_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  enum :status, { invited: "invited", active: "active", former: "former", revoked: "revoked" }, validate: true

  validates :payroll_environment, inclusion: { in: %w[live] }
  validates :user, presence: true, if: -> { active? || former? }
  validates :invite_token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :employee_belongs_to_live_company

  scope :portal_eligible, -> {
    where(status: "active").or(where(status: "former").where("former_access_until > ?", Time.current))
  }

  # Narrow decision lookup that returns only :conflict, :allowed, :none or
  # :unknown, never records. A login linked to any other employee always
  # returns :conflict, even if an allowed link also exists.
  #
  # The decision comes from the payroll_employee_login_link_decision SECURITY
  # DEFINER function, which sees every company's links even under enforced RLS
  # without a nested system read (TenantScope refuses those). Until that
  # function is installed, it falls back to a scoped read that answers
  # :unknown, which callers reject, whenever RLS hides other companies' links.
  def self.contact_email_link_decision(user_id:, company_id:, allowed_employee_ids: [])
    return :none if user_id.blank?

    allowed_ids = Array(allowed_employee_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    target_company_id = Integer(company_id, exception: false)
    return function_link_decision(user_id, target_company_id, allowed_ids) if decision_function_available?

    decision = with_system_decision_read { link_decision_for(user_id, target_company_id, allowed_ids) }
    return :unknown if decision != :conflict && other_company_links_hidden?

    decision
  end

  DECISION_FUNCTION = "payroll_employee_login_link_decision(bigint, bigint, bigint[])"
  DECISIONS = { "allowed" => :allowed, "conflict" => :conflict, "none" => :none }.freeze

  def self.function_link_decision(user_id, company_id, allowed_ids)
    sql = sanitize_sql_array([
      "SELECT payroll_employee_login_link_decision(?::bigint, ?::bigint, ?::bigint[])",
      Integer(user_id), company_id, PG::TextEncoder::Array.new.encode(allowed_ids)
    ])
    DECISIONS.fetch(connection.select_value(sql), :unknown)
  end

  def self.decision_function_available?
    connection.select_value(
      sanitize_sql_array([ "SELECT has_function_privilege(to_regprocedure(?), 'EXECUTE')", DECISION_FUNCTION ])
    ) == true
  end

  def self.link_decision_for(user_id, company_id, allowed_ids)
    scope = where(user_id: user_id).where.not(status: "revoked")
    if company_id.present? && allowed_ids.any?
      return :conflict if scope.where.not(company_id: company_id).or(scope.where.not(employee_id: allowed_ids)).exists?
      return :allowed if scope.where(company_id: company_id, employee_id: allowed_ids).exists?

      return :none
    end

    scope.exists? ? :conflict : :none
  end

  def self.with_system_decision_read(&block)
    return yield if !RlsContextGuard.enabled? || TenantScope.current

    TenantScope.as_system(reason: "Check cross-company employee account link decision", &block)
  end

  # True inside a company scope when row-level security applies to this
  # session's role on employee_account_links, so other companies' links are
  # invisible here.
  LINKS_HIDDEN_SQL = <<~SQL.squish.freeze
    SELECT c.relrowsecurity AND (c.relforcerowsecurity OR c.relowner <> r.oid)
           AND NOT r.rolbypassrls AND NOT r.rolsuper
    FROM pg_class c CROSS JOIN pg_roles r
    WHERE c.oid = 'employee_account_links'::regclass AND r.rolname = current_user
  SQL

  def self.other_company_links_hidden?
    return false unless RlsContextGuard.enabled? && TenantScope.current&.mode == "company"

    connection.select_value(LINKS_HIDDEN_SQL) == true
  end
  private_class_method :function_link_decision, :decision_function_available?, :link_decision_for,
    :with_system_decision_read, :other_company_links_hidden?

  def portal_enabled?
    company.active? && company.organization.active? && CompanyFeatures.for(company).employee_portal_enabled?
  end

  private

  def employee_belongs_to_live_company
    errors.add(:company, "must run live payroll") if company && !company.live_payroll?
    errors.add(:employee, "must belong to the link's company") if employee && employee.company_id != company_id
  end
end
