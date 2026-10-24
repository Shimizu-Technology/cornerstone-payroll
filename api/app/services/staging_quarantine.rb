# frozen_string_literal: true

# Deliberately created by the pre-migration clone task, never in production.
# Manifest rows contain only identifiers, old dispatch state and a timestamp.
class StagingQuarantine
  TABLE = "staging_quarantines"
  class Record < ApplicationRecord
    self.table_name = TABLE
    self.primary_key = %i[source_table source_id]
  end

  def self.records
    Record.unscoped
  end

  def self.connection
    ActiveRecord::Base.connection
  end

  def self.complete?
    suppressed?("__containment_complete__", 0)
  end

  def self.suppressed?(table, id)
    return false unless StagingOutboundPolicy.staging? && connection.data_source_exists?(TABLE)
    records.where(source_table: table, source_id: id).exists?
  end

  def self.excluding(scope)
    return scope unless StagingOutboundPolicy.staging? && connection.data_source_exists?(TABLE)
    scope.where.not(id: records.where(source_table: scope.table_name).select(:source_id))
  end
end
