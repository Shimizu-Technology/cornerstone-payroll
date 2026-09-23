# frozen_string_literal: true

class CheckPrintRunHistoryVerifier
  def initialize(runs:)
    @runs = runs.to_a
  end

  def call
    current_records = CheckPrintRunSelectionVerifier.load_current_records(runs: runs)

    runs.index_with do |run|
      next [ "confirmed", nil ] if run.confirmed?

      CheckPrintRunSelectionVerifier.new(run: run, current_records: current_records).call
      [ "ready", nil ]
    rescue CheckPrintRunSelectionVerifier::StaleSelectionError => e
      [ "outdated", e.message ]
    end.transform_keys(&:id)
  end

  private

  attr_reader :runs
end
