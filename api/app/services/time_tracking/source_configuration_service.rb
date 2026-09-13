# frozen_string_literal: true

module TimeTracking
  class SourceConfigurationService
    def initialize(company_id:, actor:, source: nil)
      @company_id = company_id
      @actor = actor
      @source = source || TimeTrackingSource.new(company_id: company_id)
    end

    def save!(attributes)
      source_attributes = attributes.to_h.symbolize_keys
      delegation_token = source_attributes.delete(:delegation_token).to_s.strip.presence

      TimeTrackingSource.transaction do
        source.assign_attributes(source_attributes)
        deactivate_other_sources! if source.active?
        source.save!
        save_delegation!(delegation_token) if delegation_token
      end

      source
    end

    def save_delegation!(token)
      normalized_token = token.to_s.strip
      source.errors.add(:base, "AIRE delegation token is required") if normalized_token.blank?
      unless source.source_type == "aire_services"
        source.errors.add(:base, "Delegated payroll access is only available for AIRE Services")
      end
      raise ActiveRecord::RecordInvalid, source if source.errors.any?

      TimeTrackingDelegation.transaction do
        source.lock!
        delegation = TimeTrackingDelegation.find_or_initialize_by(
          company_id: company_id,
          time_tracking_source: source,
          user: actor
        )
        delegation.token = normalized_token
        delegation.save!
        record_delegation_audit!("time_tracking_delegation#saved")
        delegation
      end
    end

    def remove_delegation!
      delegation = source.delegation_for(actor)
      return unless delegation

      TimeTrackingDelegation.transaction do
        delegation.destroy!
        record_delegation_audit!("time_tracking_delegation#removed")
      end
    end

    private

    attr_reader :company_id, :actor, :source

    def deactivate_other_sources!
      scope = TimeTrackingSource.where(company_id: company_id, active: true)
      scope = scope.where.not(id: source.id) if source.persisted?
      scope.update_all(active: false, updated_at: Time.current)
    end

    def record_delegation_audit!(action)
      AuditLog.record!(
        user: actor,
        company_id: company_id,
        action: action,
        record_type: "TimeTrackingSource",
        record_id: source.id,
        subject_name: source.name,
        event_category: "security",
        metadata: { source_type: source.source_type }
      )
    end
  end
end
