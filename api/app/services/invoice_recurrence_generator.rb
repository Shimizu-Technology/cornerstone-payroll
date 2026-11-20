# frozen_string_literal: true

class InvoiceRecurrenceGenerator
  def self.generate_due!(today: nil)
    InvoiceRecurrence.where(active: true).where("next_on <= ?", today || PayrollBusinessClock.today + 1).order(:id).pluck(:id).each do |id|
      begin
        120.times { break unless generate!(id, today: today) }
      rescue StandardError => e
        Rails.logger.error("Invoice recurrence #{id} failed: #{e.class}: #{e.message}")
      end
    end
  end

  def self.generate!(id, today: nil)
    InvoiceRecurrence.transaction do
      recurrence = InvoiceRecurrence.lock.find(id)
      local_today = today || ActiveSupport::TimeZone[recurrence.time_zone].today
      return unless recurrence.active? && recurrence.next_on <= local_today
      if recurrence.ends_on.present? && recurrence.next_on > recurrence.ends_on
        recurrence.update!(active: false)
        return
      end

      date = recurrence.next_on
      source = recurrence.source_invoice
      unless source.origin == "native" && source.issued? && !source.voided? && usable_source?(source)
        recurrence.update!(active: false)
        return
      end

      invoice = Invoice.find_by(invoice_recurrence_id: recurrence.id, recurrence_on: date)
      unless invoice
        original = source.snapshot.fetch("invoice")
        continuing = source.invoice_billing_profile.numbering_style == "continuing"
        terms = continuing ? source.invoice_recipient.payment_terms.presence || original["payment_terms"] : original["payment_terms"]
        terms_days = terms.to_s.match(/\ANet\s+(\d+)\z/i)&.captures&.first
        due_days = continuing && terms_days ? terms_days.to_i : continuing && terms.to_s.casecmp?("Due on receipt") ? 0 : recurrence.due_after_days
        period_end = recurrence.occurrence_date(recurrence.occurrence_index + 1) - 1
        invoice = Invoice.new(
          organization: recurrence.organization,
          finance_book: recurrence.finance_book,
          company: source.company,
          invoice_billing_profile: source.invoice_billing_profile,
          invoice_recipient: source.invoice_recipient,
          invoice_recurrence: recurrence,
          recurrence_on: date,
          invoice_date: date,
          due_date: date + due_days,
          due_date_manual: !continuing,
          service_period_start: date,
          service_period_end: period_end,
          currency: original["currency"],
          customer_reference: original["customer_reference"],
          notes: original["notes"],
          payment_terms: terms,
          email_subject: original["email_subject"],
          email_body: original["email_body"],
          discount_type: original["discount_type"] || "none",
          discount_value: original["discount_value"] || 0,
          created_by: recurrence.created_by,
          updated_by: recurrence.created_by
        )
        first_fee = true
        source.snapshot.fetch("line_items").each_with_index do |line, position|
          fee = line.fetch("line_kind", "service_fee") == "service_fee"
          rate = continuing && fee && first_fee ? source.invoice_recipient.default_rate || line.fetch("rate") : line.fetch("rate")
          first_fee = false if fee
          reimbursement = continuing && !fee
          description = line.fetch("description")
          if continuing
            description = if line["description_template"].present?
              line["description_template"].gsub("{month}", date.strftime("%B %Y"))
            else
              description.gsub(source.service_period_start&.strftime("%B %Y").to_s.presence || "{month}", date.strftime("%B %Y")).gsub("{month}", date.strftime("%B %Y"))
            end
          end
          invoice.line_items.build(
            item_name: line["item_name"].to_s,
            description_template: line["description_template"],
            reimbursement_review_required: reimbursement,
            line_kind: line.fetch("line_kind", "service_fee"),
            description: description,
            quantity: line.fetch("quantity"),
            rate: reimbursement ? 0 : rate,
            position: position
          )
        end
        copied_discount = invoice.discount_value
        fee_subtotal = invoice.line_items.select { |line| line.line_kind == "service_fee" }.sum(BigDecimal("0")) do |line|
          (line.quantity * line.rate).round(2, :half_up)
        end
        capped_discount = invoice.discount_type == "amount" && copied_discount > fee_subtotal
        if capped_discount
          invoice.discount_value = fee_subtotal
          invoice.notes = [ invoice.notes.presence,
                            "Review recurring discount: fixed discount capped from #{copied_discount.to_s('F')} to #{fee_subtotal.to_s('F')} #{invoice.currency} to match the regenerated service fees." ].compact.join("\n\n")
        end
        invoice.save!
        if capped_discount
          InvoiceEvent.record!(invoice: invoice, event_type: "recurring_discount_capped", actor: recurrence.created_by,
                               metadata: { original_discount: copied_discount.to_s("F"), capped_discount: fee_subtotal.to_s("F"), currency: invoice.currency })
        end
        InvoiceEvent.record!(invoice: invoice, event_type: "recurring_draft_created", actor: recurrence.created_by,
                             metadata: { recurrence_id: recurrence.id, occurrence_on: date.iso8601 })
      end
      recurrence.advance!
      invoice
    end
  end

  def self.usable_source?(source)
    snapshot = source.snapshot
    return false unless snapshot.is_a?(Hash) && snapshot["invoice"].is_a?(Hash)

    lines = snapshot["line_items"]
    lines.is_a?(Array) && lines.present? && lines.all? do |line|
      line.is_a?(Hash) && %w[description quantity rate].all? { |key| line.key?(key) }
    end
  end
end
