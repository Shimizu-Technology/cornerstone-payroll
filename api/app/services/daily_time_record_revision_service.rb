# frozen_string_literal: true

class DailyTimeRecordRevisionService
  class Error < StandardError; end

  def self.call!(record:, attributes:)
    new(record:, attributes:).call!
  end

  def initialize(record:, attributes:)
    @record = record
    @attributes = attributes.to_h.symbolize_keys
  end

  def call!
    ApplicationRecord.transaction do
      @record.lock!
      raise Error, "Only the current time record can be corrected" if @record.superseded_at?
      raise Error, "A correction reason is required" if @attributes[:override_reason].to_s.strip.length < 5

      replacement = @record.dup
      replacement.assign_attributes(@attributes)
      replacement.supersedes = @record
      replacement.revision = @record.revision + 1
      replacement.source = "manual" if replacement.source == "schedule"
      replacement.superseded_at = nil

      @record.update!(superseded_at: Time.current)
      replacement.save!
      replacement
    end
  end
end
