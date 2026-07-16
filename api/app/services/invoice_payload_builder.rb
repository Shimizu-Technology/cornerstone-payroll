# frozen_string_literal: true

class InvoicePayloadBuilder
  def self.call(invoice, detailed: false, as_of: Date.current)
    new(invoice, detailed: detailed, as_of: as_of).call
  end

  def initialize(invoice, detailed:, as_of:)
    @invoice = invoice
    @detailed = detailed
    @as_of = as_of
  end

  def call
    primary_artifact = invoice.primary_artifact
    payload = {
      id: invoice.id,
      organization_id: invoice.organization_id,
      company_id: invoice.company_id,
      invoice_recipient_id: invoice.invoice_recipient_id,
      invoice_billing_profile_id: invoice.invoice_billing_profile_id,
      recipient_name: invoice.invoice_recipient&.name,
      billing_profile_name: invoice.invoice_billing_profile&.name,
      invoice_number: invoice.invoice_number,
      invoice_date: invoice.invoice_date,
      due_date: invoice.due_date,
      currency: invoice.currency,
      customer_reference: invoice.customer_reference,
      origin: invoice.origin,
      service_period_start: invoice.service_period_start,
      service_period_end: invoice.service_period_end,
      total_amount: money(invoice.total_amount),
      amount_paid: money(invoice.amount_paid),
      credit_total: money(invoice.credit_total),
      balance_due: money(invoice.balance_due),
      status: invoice.reader_status(as_of: as_of),
      base_status: invoice.status,
      archived: invoice.archived,
      issued_at: invoice.issued_at,
      generated_at: invoice.generated_at,
      sent_at: invoice.sent_at,
      paid_at: invoice.paid_at,
      voided_at: invoice.voided_at,
      archived_at: invoice.archived_at,
      last_delivered_at: invoice.deliveries.last&.delivered_at,
      created_by_id: invoice.created_by_id,
      created_by_name: invoice.created_by&.name,
      updated_by_id: invoice.updated_by_id,
      updated_by_name: invoice.updated_by&.name,
      line_item_count: invoice.line_items.size,
      has_snapshot: invoice.snapshot.present?,
      has_artifact: primary_artifact.present?,
      legacy_artifact_missing: invoice.issued? && primary_artifact.blank?,
      created_at: invoice.created_at,
      updated_at: invoice.updated_at
    }

    payload.merge!(detail_payload) if detailed
    payload
  end

  private

  attr_reader :invoice, :detailed, :as_of

  def detail_payload
    {
      notes: invoice.notes,
      payment_terms: invoice.payment_terms,
      email_subject: invoice.email_subject,
      email_body: invoice.email_body,
      source_metadata: invoice.source_metadata,
      invoice_billing_profile: billing_profile_payload(invoice.invoice_billing_profile),
      invoice_recipient: recipient_payload(invoice.invoice_recipient),
      line_items: invoice.line_items.map { |item| line_item_payload(item) },
      artifacts: invoice.artifacts.order(:created_at, :id).map { |artifact| artifact_payload(artifact) },
      payments: invoice.payments.map { |payment| payment_payload(payment) },
      credit_notes: invoice.credit_notes.map { |credit| credit_payload(credit) },
      deliveries: invoice.deliveries.map { |delivery| delivery_payload(delivery) },
      events: invoice.events.map { |event| event_payload(event) }
    }
  end

  def recipient_payload(recipient)
    return nil unless recipient

    {
      id: recipient.id,
      organization_id: recipient.organization_id,
      company_id: recipient.company_id,
      name: recipient.name,
      email: recipient.email,
      address: recipient.address,
      default_rate: recipient.default_rate&.to_f,
      invoice_prefix: recipient.invoice_prefix,
      payment_terms: recipient.payment_terms,
      template_type: recipient.template_type,
      notes: recipient.notes,
      active: recipient.active
    }
  end

  def billing_profile_payload(profile)
    return nil unless profile

    {
      id: profile.id,
      organization_id: profile.organization_id,
      name: profile.name,
      legal_name: profile.legal_name,
      website: profile.website,
      phone: profile.phone,
      email: profile.email,
      address: profile.address,
      payment_instructions: profile.payment_instructions,
      default_payment_terms: profile.default_payment_terms,
      invoice_prefix: profile.invoice_prefix,
      remit_to: profile.remit_to,
      footer_note: profile.footer_note,
      active: profile.active,
      is_default: profile.is_default
    }
  end

  def line_item_payload(item)
    {
      id: item.id,
      description: item.description,
      quantity: item.quantity.to_f,
      rate: item.rate.to_f,
      amount: item.amount.to_f,
      service_date: item.service_date,
      position: item.position,
      created_at: item.created_at,
      updated_at: item.updated_at
    }
  end

  def artifact_payload(artifact)
    {
      id: artifact.id,
      kind: artifact.kind,
      filename: artifact.filename,
      content_type: artifact.content_type,
      byte_size: artifact.byte_size,
      sha256: artifact.sha256,
      renderer_version: artifact.renderer_version,
      template_version: artifact.template_version,
      created_by_name: artifact.created_by&.name,
      created_at: artifact.created_at
    }
  end

  def payment_payload(payment)
    {
      id: payment.id,
      amount: money(payment.amount),
      received_on: payment.received_on,
      payment_method: payment.payment_method,
      reference_number: payment.reference_number,
      notes: payment.notes,
      currency: payment.currency,
      recorded_by_name: payment.recorded_by&.name,
      reversed: payment.reversed?,
      reversed_at: payment.reversed_at,
      reversed_by_name: payment.reversed_by&.name,
      reversal_reason: payment.reversal_reason,
      system_generated: payment.system_generated,
      created_at: payment.created_at
    }
  end

  def credit_payload(credit)
    {
      id: credit.id,
      credit_number: credit.credit_number,
      issue_date: credit.issue_date,
      reason: credit.reason,
      total_amount: money(credit.total_amount),
      currency: credit.currency,
      status: credit.status,
      issued_by_name: credit.issued_by&.name,
      voided_at: credit.voided_at,
      voided_by_name: credit.voided_by&.name,
      void_reason: credit.void_reason,
      created_at: credit.created_at
    }
  end

  def delivery_payload(delivery)
    {
      id: delivery.id,
      channel: delivery.channel,
      recipient: delivery.recipient,
      delivered_at: delivery.delivered_at,
      provider_reference: delivery.provider_reference,
      notes: delivery.notes,
      artifact_id: delivery.invoice_artifact_id,
      recorded_by_name: delivery.recorded_by&.name,
      created_at: delivery.created_at
    }
  end

  def event_payload(event)
    {
      id: event.id,
      event_type: event.event_type,
      occurred_at: event.occurred_at,
      actor_name: event.actor&.name,
      metadata: event.metadata,
      created_at: event.created_at
    }
  end

  def money(value)
    BigDecimal(value.to_s).round(2).to_f
  end
end
