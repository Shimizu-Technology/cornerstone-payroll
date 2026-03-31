# frozen_string_literal: true

class OcrProcessJob < ApplicationJob
  queue_as :ocr

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(timecard_id)
    # Atomic guard: only proceed if we can claim the timecard for processing.
    # Prevents duplicate work if concurrency is ever increased.
    updated = Timecard
      .where(id: timecard_id, ocr_status: [:pending, :processing, :failed])
      .update_all(ocr_status: Timecard.ocr_statuses[:processing])
    return if updated == 0

    timecard = Timecard.find(timecard_id)

    result = TimecardOcr::OcrService.process(timecard)
    entries = Array(result["entries"])
    raise "OCR returned no entries" if entries.empty?

    timecard.transaction do
      timecard.punch_entries.delete_all

      timecard.update!(
        employee_name: result["employee_name"],
        period_start: result["period_start"],
        period_end: result["period_end"],
        overall_confidence: result["overall_confidence"],
        preprocessed_image_url: result["preprocessed_image_key"],
        raw_ocr_response: result
      )

      entries.each do |entry|
        timecard.punch_entries.create!(
          card_day: entry["card_day"],
          date: entry["date"],
          day_of_week: entry["day_of_week"],
          clock_in: entry["clock_in"],
          lunch_out: entry["lunch_out"],
          lunch_in: entry["lunch_in"],
          clock_out: entry["clock_out"],
          in3: entry["in3"],
          out3: entry["out3"],
          confidence: entry["confidence"],
          notes: entry["notes"]
        )
      end

      timecard.update!(ocr_status: :complete)
    end
  rescue StandardError => e
    # Only mark as permanently failed after all retries are exhausted.
    # ActiveJob will re-raise after the last attempt, landing here.
    if executions >= 3
      Rails.logger.error("OCR permanently failed for timecard #{timecard_id}: #{e.class}: #{e.message}")
      Timecard.where(id: timecard_id).update_all(
        ocr_status: Timecard.ocr_statuses[:failed],
        raw_ocr_response: { "error" => e.message }
      )
    else
      raise
    end
  end
end
