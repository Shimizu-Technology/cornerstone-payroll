# frozen_string_literal: true

require "httparty"
require "json"

class InvoiceAiPreviewService
  OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
  OPEN_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_OPEN_TIMEOUT_SECONDS", "15"))
  READ_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENROUTER_READ_TIMEOUT_SECONDS", "120"))
  RECIPIENT_CONTEXT_LIMIT = 50
  RECIPIENT_MATCH_LIMIT = 200

  def initialize(company:, user:, session:, message:, image_urls: [])
    @company = company
    @user = user
    @session = session
    @message = message.to_s.strip
    @image_urls = Array(image_urls).compact_blank
  end

  def call
    return fallback_preview if api_key.blank?

    normalize_preview(call_openrouter)
  rescue JSON::ParserError => e
    Rails.logger.warn("Invoice AI preview parse failed: #{e.class}: #{e.message}")
    fallback_preview
  rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.warn("Invoice AI preview request failed: #{e.class}: #{e.message}")
    fallback_preview
  end

  private

  attr_reader :company, :user, :session, :message

  def call_openrouter
    response = HTTParty.post(
      OPENROUTER_URL,
      headers: {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json"
      },
      body: {
        model: model,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: user_content }
        ],
        temperature: 0.1,
        response_format: { type: "json_object" }
      }.to_json,
      timeout: READ_TIMEOUT_SECONDS,
      open_timeout: OPEN_TIMEOUT_SECONDS
    )

    raise HTTParty::Error, "OpenRouter returned #{response.code}: #{response.body}" unless response.success?

    content = response.dig("choices", 0, "message", "content").to_s
    JSON.parse(content)
  end

  def system_prompt
    <<~PROMPT
      You prepare invoice drafts for an accounting firm. Return ONLY valid JSON.
      Do not create or imply that a real invoice was generated; you are preparing a preview for staff approval.

      Required JSON shape:
      {
        "status": "preview" or "clarification_needed",
        "message": "short staff-facing summary or question",
        "invoice_billing_profile_id": number or null,
        "invoice_billing_profile_name": string or null,
        "invoice_recipient_id": number or null,
        "invoice_recipient_name": string or null,
        "new_recipient": {
          "name": string,
          "email": string or null,
          "address": string or null,
          "default_rate": number or null,
          "invoice_prefix": string or null,
          "payment_terms": string or null,
          "template_type": "standard" or "hourly" or "project" or "tuition",
          "notes": string or null
        } or null,
        "invoice_date": "YYYY-MM-DD",
        "service_period_start": "YYYY-MM-DD" or null,
        "service_period_end": "YYYY-MM-DD" or null,
        "payment_terms": string or null,
        "notes": string or null,
        "email_subject": string or null,
        "email_body": string or null,
        "line_items": [
          {
            "description": string,
            "quantity": number,
            "rate": number,
            "service_date": "YYYY-MM-DD" or null
          }
        ]
      }

      Billing profiles are invoice-from identities. Recipients are bill-to profiles. Do not mix them.
      Use billing profile ids from the provided billing profile list when the staff asks to invoice from a specific identity; otherwise use the default billing profile.
      Use recipient ids from the provided recipient list when one matches.
      If the staff asks what clients, customers, or bill-to profiles are saved, answer using only the active invoice recipients, not billing profiles.
      If the staff asks for a bill-to recipient that is not in the recipient list and gives at least the recipient name, set invoice_recipient_id to null and fill new_recipient. Email and billing address are helpful but optional.
      If the bill-to recipient is unclear, set invoice_recipient_id and new_recipient to null and ask a clarification question.
      Use numeric quantity and rate values. Do not include currency symbols in numeric fields.
      Only include payment_terms when the staff explicitly asks for terms or the current preview already has terms they did not ask to remove.
      If the staff is modifying an existing preview, preserve fields they did not ask to change.
      For hourly invoices, use quantity as hours and rate as the hourly rate. If an attachment shows total hours and total/net pay, derive the rate from total divided by hours when no explicit rate is supplied.
      Preserve service dates when supplied. For a date range with daily hourly entries, include each billable date as its own line item when the details are available.
      Put ticket numbers, project labels, or short work descriptors into the line item description.
      Do not invent missing bill-to details, rates, or services. Ask a concise clarification question instead.
      Do not generate an invoice number; the application assigns invoice numbers.
    PROMPT
  end

  def user_prompt
    <<~PROMPT
      Company: #{company.name}
      Staff user: #{user.name}
      Today: #{Date.current.iso8601}

      Active invoice-from billing profiles:
      #{billing_profile_context}

      Active bill-to invoice recipients:
      #{recipient_context}

      Current session preview:
      #{JSON.generate(session.current_preview.presence || {})}

      Attached file references for audit trail:
      #{JSON.generate(image_urls)}

      Recent chat:
      #{message_context}

      Staff message:
      #{message}
    PROMPT
  end

  def user_content
    image_parts = image_content_parts
    return user_prompt if image_parts.empty?

    [
      { type: "text", text: user_prompt },
      *image_parts
    ]
  end

  def image_content_parts
    InvoiceAiAttachmentContentService.new(references: image_urls).content_parts
  end

  def recipient_context
    active_recipients
      .order(:name)
      .limit(RECIPIENT_CONTEXT_LIMIT)
      .map do |recipient|
        {
          id: recipient.id,
          name: recipient.name,
          email: recipient.email,
          default_rate: recipient.default_rate&.to_f,
          payment_terms: recipient.payment_terms,
          invoice_prefix: recipient.invoice_prefix
        }
      end
      .then { |rows| JSON.generate(rows) }
  end

  def billing_profile_context
    active_billing_profiles
      .ordered
      .map do |profile|
        {
          id: profile.id,
          name: profile.name,
          legal_name: profile.legal_name,
          email: profile.email,
          phone: profile.phone,
          website: profile.website,
          default_payment_terms: profile.default_payment_terms,
          invoice_prefix: profile.invoice_prefix,
          is_default: profile.is_default
        }
      end
      .then { |rows| JSON.generate(rows) }
  end

  def image_urls
    @image_urls
  end

  def message_context
    session.messages.last(8).map { |chat_message| "#{chat_message.role}: #{chat_message.content}" }.join("\n")
  end

  def normalize_preview(raw)
    recipient = resolve_recipient(raw)
    billing_profile = resolve_billing_profile(raw)
    new_recipient = normalize_new_recipient(raw["new_recipient"], recipient)
    recipient_name = recipient&.name || new_recipient&.fetch("name", nil) || raw["invoice_recipient_name"].presence
    line_items = Array(raw["line_items"]).filter_map { |item| normalize_line_item(item) }
    status = line_items.any? && (recipient || new_recipient) ? "preview" : "clarification_needed"

    {
      "status" => status,
      "message" => raw["message"].presence || default_message(recipient_name, line_items),
      "invoice_billing_profile_id" => billing_profile&.id,
      "invoice_billing_profile_name" => billing_profile&.name,
      "invoice_recipient_id" => recipient&.id,
      "invoice_recipient_name" => recipient_name,
      "new_recipient" => new_recipient,
      "invoice_date" => normalize_date(raw["invoice_date"]) || Date.current.iso8601,
      "service_period_start" => normalize_date(raw["service_period_start"]),
      "service_period_end" => normalize_date(raw["service_period_end"]),
      "payment_terms" => raw["payment_terms"].presence,
      "notes" => raw["notes"].presence,
      "email_subject" => raw["email_subject"].presence || email_subject_for(recipient_name, billing_profile),
      "email_body" => raw["email_body"].presence || email_body_for(recipient_name, billing_profile),
      "line_items" => line_items
    }
  end

  def fallback_preview
    if asks_for_saved_recipients?
      return saved_recipients_preview
    end

    recipient = detect_recipient_from_message
    billing_profile = detect_billing_profile_from_message || default_billing_profile
    line_items = detect_line_items_from_message(recipient)
    status = recipient && line_items.any? ? "preview" : "clarification_needed"

    {
      "status" => status,
      "message" => default_message(recipient&.name, line_items),
      "invoice_billing_profile_id" => billing_profile&.id,
      "invoice_billing_profile_name" => billing_profile&.name,
      "invoice_recipient_id" => recipient&.id,
      "invoice_recipient_name" => recipient&.name,
      "new_recipient" => nil,
      "invoice_date" => Date.current.iso8601,
      "service_period_start" => nil,
      "service_period_end" => nil,
      "payment_terms" => nil,
      "notes" => nil,
      "email_subject" => email_subject_for(recipient&.name, billing_profile),
      "email_body" => email_body_for(recipient&.name, billing_profile),
      "line_items" => line_items
    }
  end

  def asks_for_saved_recipients?
    message.match?(/\b(clients?|customers?|recipients?|bill-to)\b/i) &&
      message.match?(/\b(saved|list|have|available|existing)\b/i)
  end

  def saved_recipients_preview
    names = active_recipients.order(:name).limit(RECIPIENT_CONTEXT_LIMIT).pluck(:name)
    message_text = if names.any?
      "Saved bill-to recipients: #{names.join(', ')}."
    else
      "No saved bill-to recipients yet."
    end

    {
      "status" => "clarification_needed",
      "message" => message_text,
      "invoice_billing_profile_id" => default_billing_profile&.id,
      "invoice_billing_profile_name" => default_billing_profile&.name,
      "invoice_recipient_id" => nil,
      "invoice_recipient_name" => nil,
      "new_recipient" => nil,
      "invoice_date" => Date.current.iso8601,
      "service_period_start" => nil,
      "service_period_end" => nil,
      "payment_terms" => nil,
      "notes" => nil,
      "email_subject" => nil,
      "email_body" => nil,
      "line_items" => []
    }
  end

  def resolve_recipient(raw)
    recipient_id = raw["invoice_recipient_id"].presence
    recipient = InvoiceRecipient.find_by(id: recipient_id, organization_id: company.organization_id, active: true) if recipient_id
    recipient || detect_recipient_from_name(raw["invoice_recipient_name"])
  end

  def resolve_billing_profile(raw)
    profile_id = raw["invoice_billing_profile_id"].presence
    profile = InvoiceBillingProfile.find_by(id: profile_id, organization_id: company.organization_id, active: true) if profile_id
    profile || detect_billing_profile_from_name(raw["invoice_billing_profile_name"]) || detect_billing_profile_from_message || default_billing_profile
  end

  def normalize_new_recipient(raw, existing_recipient)
    return nil if existing_recipient || raw.blank?

    name = raw["name"].to_s.strip.presence
    return nil unless name

    {
      "name" => name,
      "email" => raw["email"].to_s.strip.presence,
      "address" => raw["address"].to_s.strip.presence,
      "default_rate" => normalize_optional_decimal(raw["default_rate"]),
      "invoice_prefix" => raw["invoice_prefix"].to_s.strip.presence,
      "payment_terms" => raw["payment_terms"].to_s.strip.presence,
      "template_type" => normalize_template_type(raw["template_type"]),
      "notes" => raw["notes"].to_s.strip.presence
    }
  end

  def detect_recipient_from_message
    detect_recipient_from_name(message)
  end

  def detect_billing_profile_from_message
    detect_billing_profile_from_name(message)
  end

  def detect_recipient_from_name(text)
    return nil if text.blank?

    normalized = text.downcase
    active_recipients.order(:name).limit(RECIPIENT_MATCH_LIMIT).find do |recipient|
      normalized.include?(recipient.name.downcase)
    end
  end

  def detect_billing_profile_from_name(text)
    return nil if text.blank?

    normalized = text.downcase
    active_billing_profiles.ordered.find do |profile|
      normalized.include?(profile.name.downcase)
    end
  end

  def active_recipients
    InvoiceRecipient.where(organization_id: company.organization_id, active: true)
  end

  def active_billing_profiles
    InvoiceBillingProfile.where(organization_id: company.organization_id, active: true)
  end

  def default_billing_profile
    active_billing_profiles.order(Arel.sql("is_default DESC"), :id).first
  end

  def detect_line_items_from_message(recipient)
    dollar_amounts = message.scan(/\$\s*(\d+(?:,\d{3})*(?:\.\d{1,2})?)/).flatten
    amount_text = dollar_amounts.first || message[/\b(?:for|amount|total)\s+(\d+(?:,\d{3})*(?:\.\d{1,2})?)/i, 1]
    amount = amount_text.to_s.delete(",").to_f
    return [] unless amount&.positive?

    [
      {
        "description" => detect_description || "Professional services",
        "quantity" => 1.0,
        "rate" => amount,
        "service_date" => nil
      }
    ]
  end

  def detect_description
    return "Accounting service" if message.match?(/account/i)
    return "Payroll service" if message.match?(/payroll/i)
    return "Bookkeeping service" if message.match?(/bookkeep/i)

    nil
  end

  def normalize_line_item(item)
    description = item["description"].to_s.strip.presence
    quantity = BigDecimal(item["quantity"].to_s)
    rate = BigDecimal(item["rate"].to_s)
    return nil if description.blank? || quantity <= 0 || rate.negative?

    {
      "description" => description,
      "quantity" => quantity.to_f,
      "rate" => rate.to_f,
      "service_date" => normalize_date(item["service_date"])
    }
  rescue ArgumentError
    nil
  end

  def normalize_optional_decimal(value)
    return nil if value.blank?

    decimal = BigDecimal(value.to_s)
    return nil if decimal.negative?

    decimal.to_f
  rescue ArgumentError
    nil
  end

  def normalize_template_type(value)
    value = value.to_s
    %w[standard hourly project tuition].include?(value) ? value : "standard"
  end

  def normalize_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s).iso8601
  rescue Date::Error
    nil
  end

  def default_message(recipient_name, line_items)
    return "I found a draft invoice preview for #{recipient_name}." if recipient_name.present? && line_items.any?
    return "I found the recipient. Please add the service, quantity, and amount." if recipient_name.present?

    "Which active invoice recipient should this be billed to?"
  end

  def email_subject_for(recipient_name, billing_profile)
    return nil if recipient_name.blank?

    "Invoice from #{billing_profile&.name || company.name}"
  end

  def email_body_for(recipient_name, billing_profile)
    return nil if recipient_name.blank?

    "Hi #{recipient_name},\n\nPlease find the attached invoice for your records.\n\nThank you,\n#{billing_profile&.name || company.name}"
  end

  def api_key
    ENV["OPENROUTER_API_KEY"].presence
  end

  def model
    ENV["INVOICE_AI_MODEL"].presence || ENV["OPENROUTER_MODEL"].presence || "openai/gpt-5.5"
  end
end
