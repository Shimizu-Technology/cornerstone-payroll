# frozen_string_literal: true

require "base64"
require "httparty"
require "json"
require "tempfile"

module PayrollIntake
  class AiExtractor
    OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
    OPEN_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_OPEN_TIMEOUT_SECONDS", "15"))
    READ_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_READ_TIMEOUT_SECONDS", "120"))
    MAX_FILE_BYTES = Integer(ENV.fetch("PAYROLL_INTAKE_ATTACHMENT_MAX_BYTES", (8 * 1024 * 1024).to_s))
    PDF_RENDER_LIMIT = Integer(ENV.fetch("PAYROLL_INTAKE_PDF_RENDER_LIMIT", "4"))

    def initialize(source_type:, adapter:, text: nil, files: [])
      @source_type = source_type
      @adapter = adapter
      @text = text.to_s
      @files = Array(files).compact
    end

    def call
      return unavailable_result if api_key.blank?

      payload = call_openrouter
      normalize(payload)
    rescue JSON::ParserError => e
      Rails.logger.warn("Payroll intake AI parse failed: #{e.class}: #{e.message}")
      failure_result("AI response was not valid JSON.")
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      Rails.logger.warn("Payroll intake AI request failed: #{e.class}: #{e.message}")
      failure_result("AI extraction request failed.")
    end

    private

    attr_reader :source_type, :adapter, :text, :files

    def call_openrouter
      response = HTTParty.post(
        OPENROUTER_URL,
        headers: {
          "Authorization" => "Bearer #{api_key}",
          "Content-Type" => "application/json",
          "HTTP-Referer" => "https://shimizu-technology.com",
          "X-Title" => "Cornerstone Payroll - Payroll Intake"
        },
        body: {
          model: model,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: user_content }
          ],
          temperature: 0.0,
          response_format: { type: "json_object" },
          max_tokens: 4000
        }.to_json,
        timeout: READ_TIMEOUT_SECONDS,
        open_timeout: OPEN_TIMEOUT_SECONDS
      )

      raise HTTParty::Error, "OpenRouter returned #{response.code}: #{response.body}" unless response.success?

      JSON.parse(extract_json(response.dig("choices", 0, "message", "content").to_s))
    end

    def system_prompt
      <<~PROMPT
        You extract payroll intake data for an accounting firm. Return ONLY valid JSON.
        Do not calculate payroll taxes. Do not invent employees, hours, tips, deductions, or dates.
        Use numeric values only; omit currency symbols.

        #{adapter.ai_extraction_instructions}

        #{adapter.ai_extraction_schema}
      PROMPT
    end

    def user_prompt
      <<~PROMPT
        Source type: #{source_type}

        Pasted/source text:
        #{text.presence || "(none)"}
      PROMPT
    end

    def user_content
      parts = [ { type: "text", text: user_prompt } ]
      parts.concat(file_content_parts)
      parts
    end

    def file_content_parts
      files.flat_map do |file|
        content_type = file.content_type.to_s
        data = read_limited_file(file)
        if content_type == "application/pdf" || File.extname(file.original_filename.to_s).casecmp(".pdf").zero?
          pdf_content_parts(data)
        elsif content_type.start_with?("image/")
          [ image_part(data, content_type) ]
        else
          []
        end
      end.compact
    end

    def read_limited_file(file)
      io = file.tempfile || file
      io.rewind if io.respond_to?(:rewind)
      data = io.read(MAX_FILE_BYTES + 1) || ""
      raise HTTParty::Error, "Attachment exceeds #{MAX_FILE_BYTES} bytes" if data.bytesize > MAX_FILE_BYTES

      data
    ensure
      io&.rewind if defined?(io) && io.respond_to?(:rewind)
    end

    def pdf_content_parts(data)
      rendered_images = []
      Tempfile.create([ "payroll-intake", ".pdf" ]) do |pdf|
        pdf.binmode
        pdf.write(data)
        pdf.flush
        rendered_images = TimecardOcr::CardSegmentationService.segment(pdf.path)
        rendered_images.first(PDF_RENDER_LIMIT).map do |image|
          image.rewind if image.respond_to?(:rewind)
          image_part(image.read, "image/jpeg")
        end
      ensure
        rendered_images.each do |image|
          image&.close
          image&.unlink
        end
      end
    rescue StandardError => e
      Rails.logger.warn("Payroll intake PDF render failed: #{e.class}: #{e.message}")
      []
    end

    def image_part(data, content_type)
      {
        type: "image_url",
        image_url: { url: "data:#{content_type};base64,#{Base64.strict_encode64(data)}" }
      }
    end

    def extract_json(content)
      stripped = content.strip
      return Regexp.last_match(1) if stripped.match(/\A```(?:json)?\s*(.+?)\s*```\z/m)

      stripped
    end

    def normalize(payload)
      {
        rows: Array(payload["rows"]),
        detected_period: payload["detected_period"],
        warnings: Array(payload["warnings"]).map { |message| { code: "ai_warning", message: message.to_s, severity: "warning" } }
      }
    end

    def unavailable_result
      failure_result("AI extraction is unavailable because OPENROUTER_API_KEY is not configured.")
    end

    def failure_result(message)
      { rows: [], detected_period: nil, warnings: [ { code: "ai_extraction_unavailable", message: message, severity: "warning" } ] }
    end

    def api_key
      ENV["OPENROUTER_API_KEY"]
    end

    def model
      ENV["OPENROUTER_PAYROLL_INTAKE_MODEL"].presence || ENV["OPENROUTER_MODEL"].presence || "google/gemini-3.1-pro-preview"
    end
  end
end
