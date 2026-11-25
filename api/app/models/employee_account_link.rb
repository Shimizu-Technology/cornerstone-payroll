# frozen_string_literal: true

class EmployeeAccountLink < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company
  belongs_to :employee
  belongs_to :invited_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true
  belongs_to :claim_user, class_name: "User", optional: true
  belongs_to :sign_up_reset_requested_by, class_name: "User", optional: true

  encrypts :profile_email_challenge

  INVITE_LIFETIME = 14.days
  MAX_FAILED_ATTEMPTS = 5
  LOCK_DURATION = 24.hours
  # No 0/O, 1/I/L, 2/Z, 5/S or 8/B, so a printed code reads back unambiguously.
  CODE_ALPHABET = "ACDEFGHJKMNPQRTUVWXY34679".chars.freeze
  CODE_LENGTH = 10
  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

  enum :status, { invited: "invited", active: "active", former: "former", revoked: "revoked" }, validate: true

  # A demo company's employees use the app like a real client's; a practice
  # copy's never do (the database refuses one too).
  validates :payroll_environment, inclusion: { in: %w[live migration_rehearsal] }
  validates :user, presence: true, if: -> { active? || former? }
  validates :invite_token_digest, format: { with: DIGEST_PATTERN }, allow_nil: true
  validates :invite_code_digest, format: { with: DIGEST_PATTERN }, allow_nil: true
  validates :invite_delivery, inclusion: { in: %w[email code] }, allow_nil: true
  validates :failed_activation_attempts, :invite_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :employee_belongs_to_live_company
  before_validation :take_company_payroll_environment, on: :create

  scope :portal_eligible, -> {
    now = Time.current
    where(status: "active").or(where(status: "former").where("employee_account_links.former_access_until > ?", now))
      .where("employee_account_links.activation_locked_until IS NULL OR employee_account_links.activation_locked_until <= ?", now)
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
  BIGINT = ActiveRecord::Type::Integer.new(limit: 8)
  BIGINT_ARRAY = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(BIGINT)

  # Any error from the function, including PostgreSQL refusing to read past
  # RLS when the owner no longer bypasses it (row_security = off), is
  # :unknown, which callers reject. The savepoint keeps the caller's
  # transaction usable after such an error.
  def self.function_link_decision(user_id, company_id, allowed_ids)
    binds = [
      ActiveRecord::Relation::QueryAttribute.new("login_user_id", Integer(user_id), BIGINT),
      ActiveRecord::Relation::QueryAttribute.new("company_id", company_id, BIGINT),
      ActiveRecord::Relation::QueryAttribute.new("employee_ids", allowed_ids, BIGINT_ARRAY)
    ]
    answer = transaction(requires_new: true) do
      connection.select_value("SELECT payroll_employee_login_link_decision($1, $2, $3)", "Login link decision", binds)
    end
    DECISIONS.fetch(answer, :unknown)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[EmployeeAccountLink] Login link decision failed closed: #{e.class}")
    :unknown
  end

  ELIGIBLE_LINK_FUNCTION = "payroll_employee_login_has_eligible_link(bigint, bigint, timestamp with time zone)"

  # Whether the login has another link usable right now (active, or former
  # with access still running), anywhere, even under enforced RLS: true,
  # false, or nil when the check isn't installed or fails (callers then keep
  # the login open). See db/migrate/support/login_eligible_link_function.rb.
  def self.login_has_eligible_link?(user_id:, except_link_id:, now: Time.current)
    return false if user_id.blank?
    return unless function_available?(ELIGIBLE_LINK_FUNCTION)

    binds = [
      ActiveRecord::Relation::QueryAttribute.new("login_user_id", Integer(user_id), BIGINT),
      ActiveRecord::Relation::QueryAttribute.new("except_link_id", except_link_id && Integer(except_link_id), BIGINT),
      ActiveRecord::Relation::QueryAttribute.new("now", now, ActiveRecord::Type::DateTime.new)
    ]
    answer = transaction(requires_new: true) do
      connection.select_value("SELECT payroll_employee_login_has_eligible_link($1, $2, $3)", "Login eligible link check", binds)
    end
    answer.nil? ? nil : ActiveModel::Type::Boolean.new.cast(answer)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[EmployeeAccountLink] Login eligible link check failed closed: #{e.class}")
    nil
  end

  def self.function_available?(signature)
    bind = ActiveRecord::Relation::QueryAttribute.new("function", signature, ActiveRecord::Type::String.new)
    connection.select_value("SELECT has_function_privilege(to_regprocedure($1), 'EXECUTE')", "Login link function check", [ bind ]) == true
  end

  def self.decision_function_available?
    bind = ActiveRecord::Relation::QueryAttribute.new("function", DECISION_FUNCTION, ActiveRecord::Type::String.new)
    connection.select_value("SELECT has_function_privilege(to_regprocedure($1), 'EXECUTE')", "Login link decision check", [ bind ]) == true
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
  private_class_method :function_link_decision, :decision_function_available?, :function_available?, :link_decision_for,
    :with_system_decision_read, :other_company_links_hidden?

  def self.generate_token
    SecureRandom.urlsafe_base64(32)
  end

  def self.generate_code
    Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
  end

  def self.token_digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  # Codes are short enough to brute-force from a plain hash, so they are keyed.
  def self.code_digest(code)
    OpenSSL::HMAC.hexdigest("SHA256", code_digest_key, normalize_code(code))
  end

  def self.normalize_code(code)
    code.to_s.upcase.gsub(/[\s-]/, "")
  end

  def self.code_digest_key
    Rails.application.key_generator.generate_key("employee_account_links/invite_code", 32)
  end
  private_class_method :code_digest_key

  # A sign-up reset that hasn't finished (EmployeeLinks::ResetSignUp) keeps
  # the invite closed: nothing started for it can bind or start again.
  def invite_open?(now = Time.current)
    invited? && !sign_up_reset_pending? && invite_expires_at.present? && invite_expires_at > now
  end

  def sign_up_reset_pending?
    sign_up_reset_requested_at.present?
  end

  def activation_locked?(now = Time.current)
    activation_locked_until.present? && activation_locked_until > now
  end

  # Profile reads (contacts, emergency contacts, address requests) for a
  # former link end at the cutoff set when it became former. Posting a W-2GU
  # copy can lengthen former_access_until for the copy and pay stubs only
  # (EmployeeDocuments::TaxFormRetention).
  def profile_access_open?(now = Time.current)
    return true unless former?

    cutoff = former_profile_access_until || former_access_until
    cutoff.present? && cutoff > now
  end

  def portal_enabled?
    self.class.portal_enabled_for?(company)
  end

  def self.portal_enabled_for?(company)
    company.active? && company.organization.active? && CompanyFeatures.for(company).employee_portal_enabled?
  end

  private

  def take_company_payroll_environment
    self.payroll_environment = company.payroll_environment if company
  end

  def employee_belongs_to_live_company
    errors.add(:company, "must run live payroll") if company && !(company.live_payroll? || company.demo?)
    errors.add(:employee, "must belong to the link's company") if employee && employee.company_id != company_id
  end
end
