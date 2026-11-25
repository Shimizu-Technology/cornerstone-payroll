# frozen_string_literal: true

require "base64"
require "openssl"
require "prawn"

module DeliveryConsents
  # Generates and verifies the 26 CFR 31.6051-1(j) "can you open this PDF?"
  # access-proof challenge for electronic Form W-2GU consent.
  #
  # The plaintext confirmation code appears only inside the generated PDF bytes;
  # the signed token holds only its HMAC alongside the link, employee, company,
  # user, and disclosure version/digest so an employee must actually open the PDF.
  class W2guAccessProof
    TTL = 15.minutes
    CODE_LENGTH = 6
    FILENAME = "w2gu-pdf-access-check.pdf"
    PURPOSE = "delivery_consents/w2gu_access_proof"

    Challenge = Data.define(:access_proof_token, :expires_at, :pdf_bytes, :filename) do
      def as_json(*)
        {
          access_proof_token: access_proof_token,
          expires_at: expires_at.iso8601,
          filename: filename,
          pdf_base64: Base64.strict_encode64(pdf_bytes)
        }
      end
    end

    def self.issue(link:, user:, disclosure:, now: Time.current)
      raise ArgumentError, "W-2GU disclosure is required" unless disclosure&.kind == "w2gu"

      code = generate_code
      expires_at = now + TTL
      payload = {
        "company_id" => link.company_id,
        "employee_id" => link.employee_id,
        "employee_account_link_id" => link.id,
        "user_id" => user.id,
        "disclosure_version" => disclosure.version,
        "disclosure_digest" => disclosure.digest,
        "code_hmac" => code_hmac(code),
        "exp" => expires_at.to_i
      }
      token = verifier.generate(payload, purpose: PURPOSE)
      pdf_bytes = render_pdf(code: code, company_name: link.company.name, disclosure_version: disclosure.version, issued_at: now)

      Challenge.new(
        access_proof_token: token,
        expires_at: expires_at,
        pdf_bytes: pdf_bytes,
        filename: FILENAME
      )
    end

    def self.verify?(token:, code:, link:, user:, disclosure:, now: Time.current)
      return false if token.blank? || code.blank? || link.nil? || user.nil? || disclosure.nil?
      return false unless token.is_a?(String) && code.is_a?(String)

      payload = verifier.verified(token, purpose: PURPOSE)
      return false unless payload.is_a?(Hash)

      exp = payload["exp"].to_i
      return false if exp <= now.to_i

      return false unless payload["company_id"] == link.company_id &&
        payload["employee_id"] == link.employee_id &&
        payload["employee_account_link_id"] == link.id &&
        payload["user_id"] == user.id &&
        payload["disclosure_version"] == disclosure.version &&
        payload["disclosure_digest"] == disclosure.digest

      expected_hmac = payload["code_hmac"].to_s
      actual_hmac = code_hmac(normalize_code(code))
      return false unless expected_hmac.bytesize == actual_hmac.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected_hmac, actual_hmac)
    rescue StandardError
      false
    end

    def self.normalize_code(code)
      code.to_s.upcase.gsub(/[\s-]/, "")
    end

    def self.generate_code
      alphabet = EmployeeAccountLink::CODE_ALPHABET
      Array.new(CODE_LENGTH) { alphabet[SecureRandom.random_number(alphabet.length)] }.join
    end

    def self.render_pdf(code:, company_name:, disclosure_version:, issued_at:)
      Prawn::Document.new(page_size: "LETTER", margin: 54) do |pdf|
        pdf.font("Helvetica")
        pdf.text "Form W-2GU PDF Access Check", size: 20, style: :bold
        pdf.move_down 8
        pdf.text company_name.to_s, size: 12, color: "475569"
        pdf.move_down 18
        pdf.text "If you can read this document, your device can open electronic Form W-2GU PDF files.", size: 12
        pdf.move_down 14
        pdf.text "Return to the employee app and enter this confirmation code to finish giving your consent:", size: 12
        pdf.move_down 16
        pdf.bounding_box([ 0, pdf.cursor ], width: 240, height: 54) do
          pdf.stroke_color "CBD5E1"
          pdf.stroke_bounds
          pdf.move_down 16
          pdf.text code, size: 24, style: :bold, align: :center, character_spacing: 3
        end
        pdf.move_down 20
        pdf.text "This code expires in #{(TTL / 60).to_i} minutes. You do not need to save or print this test file.", size: 10, color: "475569"
        pdf.move_down 8
        pdf.text "Disclosure version: #{disclosure_version} | Generated: #{issued_at.in_time_zone(PayrollBusinessClock::TIME_ZONE).strftime('%Y-%m-%d %H:%M %Z')}",
          size: 9, color: "64748B"
      end.render
    end

    def self.verifier
      ActiveSupport::MessageVerifier.new(secret_key, digest: "SHA256", serializer: JSON)
    end

    def self.code_hmac(normalized_code)
      OpenSSL::HMAC.hexdigest("SHA256", hmac_key, normalized_code)
    end

    def self.secret_key
      Rails.application.key_generator.generate_key("#{PURPOSE}/verifier", 32)
    end

    def self.hmac_key
      Rails.application.key_generator.generate_key("#{PURPOSE}/code_hmac", 32)
    end

    private_class_method :generate_code, :render_pdf, :verifier, :code_hmac, :secret_key, :hmac_key
  end
end
