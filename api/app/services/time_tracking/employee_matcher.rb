# frozen_string_literal: true

module TimeTracking
  class EmployeeMatcher
    THRESHOLD = 0.6
    MAX_FUZZY_CANDIDATES = 100

    def initialize(company:, source:)
      @company = company
      @source = source
      @employee_scope = Employee.active.where(company_id: company.id)
      mapping_scope = TimeTrackingEmployeeMapping.includes(:employee).where(company: company, time_tracking_source: source)
      @mappings_by_source_id = mapping_scope.index_by(&:source_user_id)
      @mappings_by_source_uuid = mapping_scope.where.not(source_user_uuid: nil).index_by(&:source_user_uuid)
    end

    def match(source_employee)
      source_user_id = source_employee["source_user_id"].to_s
      source_user_uuid = source_employee["source_user_uuid"].to_s.presence
      existing = if source_user_uuid
        by_uuid = @mappings_by_source_uuid[source_user_uuid]
        by_id = @mappings_by_source_id[source_user_id]
        if by_uuid && by_id && by_uuid.id != by_id.id
          raise TimeTrackingEmployeeMapping::IdentityConflict, "AIRE staff identity conflicts with two saved payroll mappings"
        end
        if by_id&.source_user_uuid.present? && by_id.source_user_uuid != source_user_uuid
          raise TimeTrackingEmployeeMapping::IdentityConflict, "AIRE staff ID is already linked to a different permanent identity"
        end
        by_uuid || by_id
      else
        @mappings_by_source_id[source_user_id]
      end
      return matched(existing.employee, "saved_mapping", 1.0) if existing&.employee&.active?

      email = source_employee["email"].to_s.downcase.strip
      if email.present?
        employee = @employee_scope.find_by("LOWER(email) = ?", email)
        return matched(employee, "email", 1.0) if employee
      end

      source_name = source_employee["display_name"].to_s.presence || [ source_employee["first_name"], source_employee["last_name"] ].compact.join(" ")
      best = nil
      best_score = 0.0
      fuzzy_candidates(source_name).each do |employee|
        score = trigram_similarity(source_name, employee.full_name)
        if score > best_score
          best_score = score
          best = employee
        end
      end

      return matched(best, "name", best_score.round(2)) if best && best_score >= THRESHOLD

      { employee_id: nil, employee_name: nil, match_method: "unmatched", match_score: best_score.round(2) }
    end

    private

    def fuzzy_candidates(name)
      tokens = normalize(name).split.uniq
      scope = @employee_scope.order(:last_name, :first_name).limit(MAX_FUZZY_CANDIDATES)
      return scope.to_a if tokens.empty?

      clauses = []
      values = []
      tokens.first(3).each do |token|
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"
        clauses << "first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?"
        values.concat([ pattern, pattern, pattern ])
      end

      matches = @employee_scope.where(clauses.map { |clause| "(#{clause})" }.join(" OR "), *values)
        .order(:last_name, :first_name)
        .limit(MAX_FUZZY_CANDIDATES)
        .to_a
      matches.presence || scope.to_a
    end

    def matched(employee, method, score)
      { employee_id: employee.id, employee_name: employee.full_name, match_method: method, match_score: score }
    end

    def trigram_similarity(a, b)
      a_norm = normalize(a)
      b_norm = normalize(b)
      return 1.0 if a_norm == b_norm
      return 0.0 if a_norm.blank? || b_norm.blank?

      a_tri = trigrams(a_norm)
      b_tri = trigrams(b_norm)
      union = (a_tri | b_tri)
      union.empty? ? 0.0 : ((a_tri & b_tri).size.to_f / union.size)
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def trigrams(value)
      padded = "  #{value} "
      (0..padded.length - 3).map { |i| padded[i, 3] }
    end
  end
end
