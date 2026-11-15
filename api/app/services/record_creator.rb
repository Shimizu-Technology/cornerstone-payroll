# frozen_string_literal: true

class RecordCreator
  CREATION_ACTIONS = %w[companies#create companies#created test_workspace#create migration_rehearsal#create training_replay#create employees#create employees#created client_employees#create pay_periods#create pay_periods#created].freeze

  def self.for_companies(companies)
    logs = AuditLog.where(record_type: RecordActivityQuery::RECORD_TYPES.fetch("companies").fetch(:audit_aliases),
      record_id: companies.map(&:id), company_id: companies.map(&:id), action: CREATION_ACTIONS).includes(:user).oldest_first.to_a.select { |log| log.company_id == log.record_id }.group_by(&:record_id)
    companies.index_with do |company|
      log = logs[company.id]&.first
      if log
        call(company, creation_log: log)
      elsif company.created_by
        { name: company.created_by.name, role: company.created_by.role, created_at: company.created_at }
      end
    end.transform_keys(&:id)
  end

  def self.call(record, creation_log: nil)
    creation_log ||= AuditLog.where(record_id: record.id,
      record_type: RecordActivityQuery::RECORD_TYPES.fetch(record.class.table_name).fetch(:audit_aliases),
      company_id: record.is_a?(Company) ? record.id : record.company_id, action: CREATION_ACTIONS).oldest_first.first
    if creation_log
      return nil unless creation_log.actor_name.present? || creation_log.user

      return { name: creation_log.actor_name.presence || creation_log.user&.name || "Unknown (before tracking)", role: creation_log.actor_role.presence || creation_log.user&.role,
               created_at: creation_log.created_at }
    end
    creator = record.created_by
    return nil unless creator

    { name: creator.name, role: creator.role, created_at: record.created_at }
  end
end
