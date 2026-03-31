# frozen_string_literal: true

class OcrProcessJob < ApplicationJob
  queue_as :default

  def perform(timecard_id)
    timecard = Timecard.find_by(id: timecard_id)
    return unless timecard
    return unless timecard.pending? || timecard.processing? || timecard.failed?

    timecard.update!(ocr_status: :processing)

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
  rescue => e
    Rails.logger.error("OCR failed for timecard #{timecard_id}: #{e.class}: #{e.message}")
    timecard&.update!(
      ocr_status: :failed,
      raw_ocr_response: { "error" => e.message }
    )
  end
end
