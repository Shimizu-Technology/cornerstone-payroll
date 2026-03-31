require "httparty"
require "base64"
require "json"

module TimecardOcr
  class OcrService
    MAX_RETRIES = Integer(ENV.fetch("OPENROUTER_MAX_RETRIES", "2"))
    BACKOFF_SECONDS = ENV.fetch("OPENROUTER_BACKOFF_SECONDS", "2,5").split(",").filter_map { |v| Integer(v, exception: false) }.freeze
    OPENROUTER_OPEN_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_OPEN_TIMEOUT_SECONDS", "15"))
    OPENROUTER_READ_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_READ_TIMEOUT_SECONDS", "120"))

    VERIFICATION_CONFIDENCE_THRESHOLD = 0.95
    ROW_GRID_TOP_RATIO = 0.35
    ROW_GRID_BOTTOM_RATIO = 0.91

    def self.process(timecard)
      new(timecard).call
    end

    def initialize(timecard)
      @timecard = timecard
    end

    def call
      images, preprocessed_key = prepare_images

      raw = extract_raw(images)
      raw = verify_and_correct(images, raw)
      raw = OcrDigitConsistencyService.correct(raw)
      result = OcrResponseNormalizer.normalize(raw, reference_date: @timecard.created_at.to_date)

      if OcrResultEvaluator.needs_stronger_review?(result) && strong_model != primary_model
        fallback_raw = extract_raw(images, model: strong_model)
        fallback_raw = verify_and_correct(images, fallback_raw, model: strong_model)
        fallback_raw = OcrDigitConsistencyService.correct(fallback_raw)
        fallback = OcrResponseNormalizer.normalize(fallback_raw, reference_date: @timecard.created_at.to_date)
        result = fallback if OcrResultEvaluator.score(fallback) > OcrResultEvaluator.score(result)
      end

      result.merge("preprocessed_image_key" => preprocessed_key)
    end

    private

    def prepare_images
      original_tmp = StorageService.download_to_tempfile(@timecard.image_url)
      reference_tmp = preprocess_image(original_tmp.path, variant: :reference)
      enhanced_tmp = preprocess_image(original_tmp.path, variant: :enhanced)
      row_crop_tmp = crop_row_area(enhanced_tmp.path)

      preprocessed_key = "#{@timecard.id}/preprocessed-#{SecureRandom.uuid}.jpg"
      preprocessed_url = StorageService.upload(enhanced_tmp.path, preprocessed_key, content_type: "image/jpeg")

      images = {
        reference: Base64.strict_encode64(File.read(reference_tmp.path)),
        enhanced: Base64.strict_encode64(File.read(enhanced_tmp.path)),
        row_crop: Base64.strict_encode64(File.read(row_crop_tmp.path))
      }

      [images, preprocessed_url]
    ensure
      [original_tmp, reference_tmp, enhanced_tmp, row_crop_tmp].each do |tmp|
        tmp&.close
        tmp&.unlink
      end
    end

    def preprocess_image(path, variant:)
      image = MiniMagick::Image.open(path)
      image.combine_options do |cmd|
        cmd.auto_orient
        cmd.resize "4000x4000>"
        cmd.deskew "40%"
        cmd.strip
      end

      image.combine_options do |cmd|
        case variant
        when :reference
          cmd.quality "92"
        when :enhanced
          cmd.colorspace "Gray"
          cmd.normalize
          cmd.contrast
          cmd.sharpen "0x1.2"
          cmd.brightness_contrast "15x20"
          cmd.quality "92"
        end
      end

      image.format "jpeg"
      out = Tempfile.new(["processed-#{variant}", ".jpg"])
      out.binmode
      image.write(out.path)
      out
    end

    def crop_row_area(enhanced_path)
      image = MiniMagick::Image.open(enhanced_path)
      width = image.width
      height = image.height

      top = (height * ROW_GRID_TOP_RATIO).round
      crop_height = (height * (ROW_GRID_BOTTOM_RATIO - ROW_GRID_TOP_RATIO)).round

      cropped = MiniMagick::Image.open(enhanced_path)
      cropped.crop("#{width}x#{crop_height}+0+#{top}")
      cropped.format "jpeg"

      out = Tempfile.new(["row-crop", ".jpg"])
      out.binmode
      cropped.write(out.path)
      out
    end

    def extract_raw(images, model: primary_model)
      raw = call_openrouter_with_retry(
        [
          { label: "Original timecard (color)", image_data: images[:reference] },
          { label: "Enhanced timecard (grayscale, high contrast)", image_data: images[:enhanced] }
        ],
        prompt: full_card_prompt,
        model: model
      )
      parse_response(raw)
    end

    def verify_and_correct(images, raw_result, model: primary_model)
      entries = Array(raw_result["entries"])
      questionable_indices = entries.each_with_index.filter_map do |entry, i|
        has_punches = %w[clock_in lunch_out lunch_in clock_out].any? { |f| entry[f].present? }
        next unless has_punches
        next unless entry["confidence"].to_f < VERIFICATION_CONFIDENCE_THRESHOLD || entry["notes"].present?
        i
      end

      return raw_result if questionable_indices.empty?

      rows_summary = questionable_indices.map do |i|
        entry = entries[i]
        fields = %w[clock_in lunch_out lunch_in clock_out].map do |f|
          "#{f}=#{entry[f] || 'null'}"
        end.join(", ")
        "Row #{entry['card_day'] || i + 1}: #{fields}"
      end.join("\n")

      verification_raw = call_openrouter_with_retry(
        [
          { label: "Zoomed-in row area — examine each digit carefully", image_data: images[:row_crop] },
          { label: "Full card for cross-row comparison", image_data: images[:enhanced] }
        ],
        prompt: verification_prompt(rows_summary),
        model: model
      )

      corrections = parse_response(verification_raw)
      apply_corrections(raw_result, corrections)
    rescue => e
      Rails.logger.warn("OCR verification pass failed: #{e.message}")
      raw_result
    end

    def apply_corrections(raw_result, corrections)
      corrected_by_day = Array(corrections["entries"]).index_by { |e| e["card_day"].to_i }
      return raw_result if corrected_by_day.empty?

      corrected_entries = Array(raw_result["entries"]).map do |entry|
        correction = corrected_by_day[entry["card_day"].to_i]
        next entry unless correction

        merged = entry.dup
        %w[clock_in lunch_out lunch_in clock_out in3 out3].each do |field|
          merged[field] = correction[field] if correction.key?(field)
        end
        if correction["confidence"].present?
          merged["confidence"] = [entry["confidence"].to_f, correction["confidence"].to_f].max.round(2)
        end
        merged
      end

      raw_result.merge("entries" => corrected_entries)
    end

    def full_card_prompt
      <<~PROMPT
        You are reading a Pyramid paper time card. Return ONLY valid JSON, no markdown, no explanation.

        You are given TWO images of the same card:
        1. Original color photo — use for natural contrast and seeing the pen ink color
        2. Enhanced grayscale version — use for sharper digit edges

        Compare both images when reading any unclear digit.

        CARD LAYOUT:
        The header has the employee name and pay period (handwritten).
        Below are 15 printed rows. Each row has printed column headers:
          DATE | IN | OUT | IN | OUT | IN | OUT | TOTAL
        The six punch columns we read, left to right:
          1st IN  = clock_in   (morning arrival)
          1st OUT = lunch_out  (first break/lunch departure)
          2nd IN  = lunch_in   (return from first break/lunch)
          2nd OUT = clock_out  (second break departure OR leaving for the day)
          3rd IN  = in3        (return from second break, if applicable)
          3rd OUT = out3       (leaving for the day after second break)
        Most employees use only 4 columns (clock_in through clock_out).
        Some employees use all 6 columns when they take multiple breaks.

        READING HANDWRITTEN DIGITS — CRITICAL:
        Times are handwritten in small boxes. The most common misreads on these cards:
        - 0 vs 6: '6' has a curved tail descending from upper-left; '0' is a closed oval with no tail
        - 0 vs 3: '3' is open on the left with two right-facing bumps; '0' is fully closed
        - 1 vs 4 vs 7: '1' is a vertical stroke; '4' has a horizontal crossbar; '7' has a flat top
        - 3 vs 5: '5' has a flat horizontal top then curves right; '3' has two right bumps with no flat top
        - 3 vs 8: '8' has two closed loops; '3' is open on the left side
        Examine each minute digit INDIVIDUALLY by looking at the actual pen strokes:
        - If you read :00, verify the second digit is truly a 0 and not a 6, 3, or 5
        - If you read :30, verify the 3 is truly a 3 and not a 5 or 0
        - Compare the same worker's handwriting across rows — the same digit looks similar everywhere
        - Do NOT default to round numbers. Read exactly what is written.

        COLUMN PLACEMENT:
        - 6 punches = full day with two breaks (clock_in, lunch_out, lunch_in, clock_out, in3, out3)
        - 4 punches = standard day with one lunch break (clock_in, lunch_out, lunch_in, clock_out)
        - 2 punches in the first IN and first OUT columns = half day or no lunch break.
          Report as clock_in and clock_out.
        - If columns 5 and 6 (3rd IN/OUT pair) are filled, report them as in3 and out3
        - Never read from the TOTAL column at the far right
        - The A/P or AM/PM suffix is a small letter written after the time digits

        AM/PM INFERENCE (when no A/P is written):
        - clock_in before noon → AM (7:50 = 07:50)
        - lunch_out around noon → PM (12:05 = 12:05)
        - lunch_in early afternoon → PM (1:20 = 13:20)
        - clock_out afternoon → PM (4:46 = 16:46, 5:13 = 17:13)
        - in3 afternoon → PM (return from second break)
        - out3 afternoon/evening → PM (final departure for the day)
        - Note: for 6-punch rows, the first break may be in the morning (e.g., 8:45A out, 9:54A in)

        Return this exact structure:
        {
          "employee_name": "string or null",
          "period_start": "YYYY-MM-DD or null",
          "period_end": "YYYY-MM-DD or null",
          "entries": [
            {
              "card_day": 1,
              "date": "YYYY-MM-DD or null",
              "day_of_week": "Mon or null",
              "clock_in": "HH:MM or null",
              "lunch_out": "HH:MM or null",
              "lunch_in": "HH:MM or null",
              "clock_out": "HH:MM or null",
              "in3": "HH:MM or null",
              "out3": "HH:MM or null",
              "confidence": 0.95,
              "notes": "any anomaly or null"
            }
          ],
          "overall_confidence": 0.9
        }

        Rules:
        - Return exactly 15 entries, one per printed row, top to bottom
        - card_day must match the printed row number at the far left
        - Times in 24-hour HH:MM format
        - Blank rows: all punch fields null, confidence 0.99
        - Never copy punches from one row to another
        - If a digit is too ambiguous, return null and explain in notes
        - confidence is 0.0–1.0 per entry reflecting how clearly you can read each digit
        - Return ONLY the JSON object
      PROMPT
    end

    def verification_prompt(rows_summary)
      <<~PROMPT
        You are re-examining specific rows of a Pyramid time card to catch digit-reading errors.
        Return ONLY valid JSON, no markdown, no explanation.

        You are given TWO images:
        1. A ZOOMED-IN crop of just the row grid area — use this as your primary source for reading digits
        2. The full card for cross-row handwriting comparison

        Here are the times extracted in the first pass — some may have wrong digits:
        #{rows_summary}

        IMPORTANT: The zoomed image shows ONLY the row grid (rows 1-15), not the header.
        Row 1 is at the top of the zoomed image, row 15 is at the bottom.

        DIGIT VERIFICATION — examine every digit stroke by stroke:
        - For each minute value, look at the tens digit and ones digit SEPARATELY
        - 0 vs 6: Does the digit have a descending tail at top-left (6) or is it a clean closed oval (0)?
        - 0 vs 3: Is the left side fully closed (0) or open with bumps on the right (3)?
        - 1 vs 4 vs 7: Vertical stroke (1), horizontal crossbar (4), or flat top line (7)?
        - 5 vs 3: Flat horizontal top (5) or no flat top with two bumps (3)?
        - Compare this worker's digit style across ALL rows — if row 2 has a clear "05" in lunch_out,
          then a similar shape in row 6 is also likely "05", not "35"
        - If a time was read as :00 or :30, verify those are the actual digits, not :06/:03/:05/:35
        - Look at the actual ink strokes in the ZOOMED image — do not rely on your first-pass reading

        Return ONLY the corrected rows in this structure:
        {
          "entries": [
            {
              "card_day": 2,
              "clock_in": "HH:MM or null",
              "lunch_out": "HH:MM or null",
              "lunch_in": "HH:MM or null",
              "clock_out": "HH:MM or null",
              "in3": "HH:MM or null",
              "out3": "HH:MM or null",
              "confidence": 0.95,
              "notes": "what changed and why, or null"
            }
          ]
        }

        Rules:
        - Include ONLY the rows listed above
        - Return each time as you now read it from the ZOOMED image (corrected or unchanged)
        - Times in 24-hour HH:MM format
        - Do NOT round to :00 or :30 — read the actual written digits
        - Return ONLY the JSON object
      PROMPT
    end

    def call_openrouter_with_retry(image_payloads, prompt:, model:)
      retries = 0
      begin
        call_openrouter(image_payloads, prompt:, model:)
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ETIMEDOUT => e
        retries += 1
        if retries <= MAX_RETRIES
          sleep(BACKOFF_SECONDS[retries - 1] || BACKOFF_SECONDS.last || 0)
          retry
        else
          raise "OpenRouter request timed out after #{OPENROUTER_READ_TIMEOUT_SECONDS}s: #{e.class}"
        end
      rescue => e
        retries += 1
        if retries <= MAX_RETRIES
          sleep(BACKOFF_SECONDS[retries - 1] || BACKOFF_SECONDS.last || 0)
          retry
        else
          raise
        end
      end
    end

    def call_openrouter(image_payloads, prompt:, model:)
      content = image_payloads.flat_map do |payload|
        blocks = []
        blocks << { type: "text", text: payload[:label] } if payload[:label].present?
        blocks << {
          type: "image_url",
          image_url: { url: "data:image/jpeg;base64,#{payload[:image_data]}" }
        }
        blocks
      end
      content << { type: "text", text: prompt }

      response = HTTParty.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers: {
          "Authorization" => "Bearer #{ENV['OPENROUTER_API_KEY']}",
          "Content-Type" => "application/json",
          "HTTP-Referer" => "https://shimizu-technology.com",
          "X-Title" => "Cornerstone Payroll - Timecard OCR"
        },
        body: {
          model: model,
          messages: [
            {
              role: "user",
              content: content
            }
          ],
          temperature: 0.0,
          max_tokens: 4000
        }.to_json,
        open_timeout: OPENROUTER_OPEN_TIMEOUT_SECONDS,
        read_timeout: OPENROUTER_READ_TIMEOUT_SECONDS,
        timeout: OPENROUTER_READ_TIMEOUT_SECONDS
      )

      raise "OpenRouter error: #{response.code} #{response.body}" unless response.success?
      response.parsed_response
    end

    def primary_model
      ENV["OPENROUTER_MODEL"].presence || "openai/gpt-5.4"
    end

    def strong_model
      ENV["OPENROUTER_STRONG_MODEL"].presence ||
        ENV["OPENROUTER_FALLBACK_MODEL"].presence ||
        primary_model
    end

    def parse_response(response)
      content = response.dig("choices", 0, "message", "content")
      raise "Empty OCR response" if content.blank?

      JSON.parse(extract_json(content))
    end

    def extract_json(content)
      stripped = content.strip
      return Regexp.last_match(1) if stripped.match(/\A```(?:json)?\s*(.+?)\s*```\z/m)

      stripped
    end
  end
end
