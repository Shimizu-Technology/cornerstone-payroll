# frozen_string_literal: true

module EmployeeProfileIdentity
  OWN_RECORD_SIGNALS = %w[strong name_only].freeze

  def self.own_record?(employee, user)
    decision = EmployeeAccountLink.contact_email_link_decision(
      user_id: user.id, company_id: employee.company_id, allowed_employee_ids: [ employee.id ]
    )

    return true if decision == :allowed

    # The function reports a conflict for multiple links and ignores revoked
    # links. A link to this record still identifies the person in both cases.
    return true if EmployeeAccountLink.exists?(company_id: employee.company_id, employee_id: employee.id, user_id: user.id)
    raise LinkCheckUnavailable, "We couldn’t verify who can make this address change. Please try again." if decision == :unknown

    AuditLog.where(
      company_id: employee.company_id, record_type: "employees", record_id: employee.id,
      action: "employees#confirm_same_person_email"
    ).where("metadata ->> 'confirmed_login_user_id' = ?", user.id.to_s).exists?
  end

  def self.own_record_for_client_managed?(employee, user)
    own_record_signal_for_client_managed(employee, user).present?
  end

  def self.own_record_signal_for_client_managed(employee, user, confirming_own_login: false)
    return nil unless employee && user
    return "strong" if confirming_own_login || strong_own_record_for_client_managed?(employee, user)
    return "name_only" if name_only_own_record_for_client_managed?(employee, user)

    nil
  end

  def self.name_only_own_record_for_client_managed?(employee, user)
    return false unless employee && user
    return true if normalized_full_name_match?(employee.first_name, employee.last_name, user.name)

    sticky_own_record?(employee, user, include_name_snapshots: true)
  end

  # Strong own-record signals (account link / confirmed email audit, normalized
  # email match, or sticky prior strong own-record). Used to hard-block
  # self-terminate and self-rehire without blocking unrelated employees who
  # merely share tokens with a manager's name (e.g. "Jose Cruz Camacho" vs
  # "Jose Camacho").
  def self.strong_own_record_for_client_managed?(employee, user)
    return false unless employee && user
    return true if own_record?(employee, user)
    return true if normalized_email_match?(employee.email, user.email)

    sticky_own_record?(employee, user, include_name_snapshots: false)
  end

  def self.possible_self_created_hire_signal(employee, user, same_person_confirmed: false)
    return "strong" if same_person_confirmed
    return nil unless employee && user
    return "strong" if normalized_email_match?(employee.email, user.email)
    return "name_only" if normalized_full_name_match?(employee.first_name, employee.last_name, user.name)

    nil
  end

  def self.possible_self_created_hire?(employee, user, same_person_confirmed: false)
    possible_self_created_hire_signal(employee, user, same_person_confirmed: same_person_confirmed).present?
  end

  def self.normalized_email_match?(left, right)
    left_email = EmployeeContactValidator.normalize_email(left)
    right_email = EmployeeContactValidator.normalize_email(right)
    left_email.present? && right_email.present? && left_email == right_email
  end

  def self.normalize_full_name(value)
    value.to_s.downcase.gsub(/[^\p{Alnum}\s]/, " ").squish.presence
  end

  def self.name_tokens(value)
    normalize_full_name(value).to_s.split
  end

  # Token-set matching on first + last name so middle names, middle initials,
  # suffixes, or "Last, First" order (e.g. "Sloane M. Owner" vs "Sloane Owner")
  # cannot bypass self-record detection. Common names (including common Guam
  # names) may produce intentional fail-safe false positives: edits route to
  # Cornerstone staff for review, while terminate/rehire hard-block only on
  # strong own-record signals and flag name-only matches on verification items.
  def self.normalized_full_name_match?(first_name, last_name, user_name)
    first_tokens = name_tokens(first_name)
    last_tokens = name_tokens(last_name)
    actor_tokens = name_tokens(user_name)
    return false if first_tokens.empty? || last_tokens.empty? || actor_tokens.length < 2

    employee_tokens = (first_tokens + last_tokens).uniq
    return true if employee_tokens.all? { |token| actor_tokens.include?(token) }

    actor_tokens.all? { |token| employee_tokens.include?(token) } &&
      (actor_tokens & first_tokens).any? &&
      (actor_tokens & last_tokens).any?
  end

  # Once an employee record has been identified as belonging to a client actor
  # (via a prior own-record change request, an own-record / possible-self-hire
  # verification item, or a prior recorded identity snapshot), keep treating it
  # as that actor's own record even if the record is later renamed or re-emailed.
  def self.sticky_own_record?(employee, user, include_name_snapshots: true)
    return false unless employee&.persisted? && user&.persisted?

    change_requests = EmployeeChangeRequest.for_company(employee.company_id)
      .where(employee_id: employee.id, own_record: true, requested_by_id: user.id)
    change_requests = change_requests.where(own_record_signal: [ nil, "strong" ]) unless include_name_snapshots
    return true if change_requests.exists?

    base_scope = EmployeeVerificationItem.where(company_id: employee.company_id, employee_id: employee.id)
    marker_scope = base_scope.where(
      "metadata ->> 'own_record_actor_id' = :uid OR (metadata ->> 'possible_self_created_hire' = 'true' AND source_actor_id = :user_id)",
      uid: user.id.to_s,
      user_id: user.id
    )
    marker_scope = marker_scope.where("metadata ->> 'own_record_signal' = ?", "strong") unless include_name_snapshots
    return true if marker_scope.exists?

    snapshot_scope = if include_name_snapshots
      base_scope.where(
        "before_values ? 'email' OR after_values ? 'email' OR " \
        "(before_values ? 'first_name' AND before_values ? 'last_name') OR " \
        "(after_values ? 'first_name' AND after_values ? 'last_name') OR " \
        "metadata ? 'identity_name_before' OR metadata ? 'identity_name_after'"
      ).select(:id, :before_values, :after_values, :metadata)
    else
      base_scope.where("before_values ? 'email' OR after_values ? 'email'")
        .select(:id, :before_values, :after_values)
    end

    snapshot_scope.any? do |item|
      historical_item_matches_user?(item, user, include_name_snapshots: include_name_snapshots)
    end
  end

  def self.historical_item_matches_user?(item, user, include_name_snapshots:)
    return true if historical_values_match_user?(item.before_values, user, include_name_snapshots: include_name_snapshots)
    return true if historical_values_match_user?(item.after_values, user, include_name_snapshots: include_name_snapshots)
    return false unless include_name_snapshots

    meta = item.metadata.to_h
    historical_name_snapshot_matches_user?(meta["identity_name_before"], user) ||
      historical_name_snapshot_matches_user?(meta["identity_name_after"], user)
  end
  private_class_method :historical_item_matches_user?

  def self.historical_values_match_user?(values, user, include_name_snapshots:)
    return false unless values.is_a?(Hash) && values.present?

    snapshot = values.stringify_keys
    return true if snapshot["email"].present? && normalized_email_match?(snapshot["email"], user.email)
    return false unless include_name_snapshots

    historical_name_snapshot_matches_user?(snapshot, user)
  end
  private_class_method :historical_values_match_user?

  # Match first and last name ONLY when both come from the same historical
  # snapshot, never combining an earlier field with the current employee row.
  def self.historical_name_snapshot_matches_user?(snapshot, user)
    return false unless snapshot.is_a?(Hash)

    data = snapshot.stringify_keys
    first = data["first_name"].presence
    last = data["last_name"].presence
    return false unless first && last

    normalized_full_name_match?(first, last, user.name)
  end
  private_class_method :historical_name_snapshot_matches_user?

  class LinkCheckUnavailable < StandardError; end
end
