# frozen_string_literal: true

# Moves an existing payroll company into a new organization without changing its
# id or any company-owned payroll records. The caller must review the preview and
# supply the source organization id again when executing.
class OrganizationCompanyTransfer
  class Conflict < StandardError; end

  def initialize(company:, billing_profile: nil)
    @company = company
    @source = company.organization
    @billing_profile = billing_profile
  end

  def preview
    invoices = selected_invoices
    {
      company: { id: company.id, name: company.name },
      source_organization: { id: source.id, name: source.name },
      payroll_periods: company.pay_periods.count,
      employee_count: company.employees.count,
      billing_profiles: source.invoice_billing_profiles.order(:name).map do |profile|
        { id: profile.id, name: profile.name, legal_name: profile.legal_name,
          invoice_count: profile.invoices.count }
      end,
      selected_invoice_count: invoices.count,
      company_invoice_count: Invoice.where(company_id: company.id).count,
      selected_invoice_numbers: invoices.order(:id).pluck(:invoice_number),
      source_invoice_numbers_to_unlink: source_invoices_to_unlink.order(:id).pluck(:invoice_number),
      assistant_sessions_to_move: selected_invoice_sessions.count,
      assistant_sessions_to_unlink: source_invoice_sessions.count,
      home_users_to_move: home_users.where(role: %w[client employee]).count,
      staff_home_users_to_rehome: home_users.where.not(role: %w[client employee]).count,
      assignments_to_remove: CompanyAssignment.where(company_id: company.id).count,
      blockers: blockers
    }
  end

  def transfer!(name:, slug:, expected_source_organization_id:, actor:, issuer_legal_name: nil)
    raise Conflict, "Source organization changed; preview again" unless source.id == expected_source_organization_id.to_i
    raise Conflict, "Organization name is required" if name.to_s.strip.empty?
    raise Conflict, "Organization slug is required" if slug.to_s.strip.empty?
    raise Conflict, "Invoice issuer legal name is required" if billing_profile && issuer_legal_name.to_s.strip.empty?

    ApplicationRecord.transaction do
      source.lock!
      company.lock!
      raise Conflict, "Company moved; preview again" unless company.organization_id == source.id
      problems = blockers
      raise Conflict, problems.join("; ") if problems.any?

      destination = Organization.create!(name: name.strip, slug: slug.strip, status: "active", client_limit: 1)
      invoice_count = selected_invoices.count
      source_invoice_ids = source_invoices_to_unlink.pluck(:id)
      source_session_ids = source_invoice_sessions.pluck(:id)
      fallback_company_id = source.primary_company_id
      moving_user_ids = home_users.where(role: %w[client employee]).pluck(:id)
      home_users.where.not(role: %w[client employee]).update_all(company_id: fallback_company_id)
      CompanyAssignment.where(company_id: company.id).delete_all

      company.update!(organization: destination)
      destination.update!(primary_company: company)
      User.where(id: moving_user_ids).update_all(organization_id: destination.id)

      transfer_invoices!(destination, issuer_legal_name: issuer_legal_name)
      # Legacy invoice creation used the selected payroll company even when the
      # sender was Cornerstone. Keep those invoices and their chats in the source
      # organization, without a cross-tenant company reference.
      Invoice.where(id: source_invoice_ids).update_all(company_id: nil)
      InvoiceChatSession.where(id: source_session_ids).update_all(company_id: nil)
      AuditLog.where(company_id: company.id, organization_id: source.id).update_all(organization_id: destination.id)

      metadata = { company_id: company.id, source_organization_id: source.id,
                   destination_organization_id: destination.id, invoice_count: invoice_count }
      AuditLog.record!(user: actor, organization_id: source.id, company_id: nil,
                       action: "organizations#company_transferred_out", record_type: "companies",
                       record_id: company.id, subject_name: company.name, metadata: metadata)
      AuditLog.record!(user: actor, organization_id: destination.id, company_id: company.id,
                       action: "organizations#company_transferred_in", record_type: "companies",
                       record_id: company.id, subject_name: company.name, metadata: metadata)
      destination
    end
  end

  private

  attr_reader :company, :source, :billing_profile

  def home_users
    User.where(organization_id: source.id, company_id: company.id)
  end

  def selected_invoices
    return Invoice.none unless billing_profile

    Invoice.where(organization_id: source.id, invoice_billing_profile_id: billing_profile.id)
  end

  def source_invoices_to_unlink
    Invoice.where(organization_id: source.id, company_id: company.id)
           .where.not(id: selected_invoices.select(:id))
  end

  def selected_invoice_sessions
    InvoiceChatSession.where(organization_id: source.id, invoice_id: selected_invoices.select(:id))
  end

  def source_invoice_sessions
    InvoiceChatSession.where(organization_id: source.id, company_id: company.id)
                      .where.not(id: selected_invoice_sessions.select(:id))
  end

  def blockers
    issues = []
    issues << "Company is the source organization's primary company" if source.primary_company_id == company.id
    issues << "Source organization needs a different primary company for staff" unless source.primary_company_id && source.primary_company_id != company.id
    issues << "Selected billing profile does not belong to the source organization" if billing_profile && billing_profile.organization_id != source.id
    issues << "Company has an invoice in another organization" if Invoice.where(company_id: company.id).where.not(organization_id: source.id).exists?
    issues << "Company has an invoice assistant session in another organization" if InvoiceChatSession.where(company_id: company.id).where.not(organization_id: source.id).exists?
    issues << "Selected billing profile has invoices assigned to another company" if selected_invoices.where.not(company_id: [ nil, company.id ]).exists?
    issues << "A linked test workspace must be resolved first" if Company.where(migration_source_company_id: company.id).exists?
    issues << "Client user has assignments to other companies" if CompanyAssignment.where(user_id: home_users.where(role: %w[client employee]).select(:id)).where.not(company_id: company.id).exists?
    issues << "Unlinked invoice assistant sessions need manual assignment first" if source_invoice_sessions.where(invoice_id: nil).exists?
    issues << "Selected invoice assistant uses another recipient" if selected_invoice_sessions.joins(:invoice)
      .where("invoice_chat_sessions.invoice_recipient_id IS NOT NULL AND invoice_chat_sessions.invoice_recipient_id <> invoices.invoice_recipient_id").exists?
    issues << "Selected invoice assistant belongs to another company" if selected_invoice_sessions.where.not(company_id: [ nil, company.id ]).exists?
    issues << "Recurring invoices must be paused and resolved first" if InvoiceRecurrence.where(source_invoice_id: selected_invoices.select(:id)).exists?
    issues << "Scheduled invoice email must be cancelled or resolved first" if InvoiceSendSchedule.where(invoice_id: selected_invoices.select(:id)).exists?
    issues
  end

  def transfer_invoices!(destination, issuer_legal_name:)
    invoice_ids = selected_invoices.pluck(:id)
    session_ids = selected_invoice_sessions.pluck(:id)
    recipient_ids = Invoice.where(id: invoice_ids).distinct.pluck(:invoice_recipient_id)

    recipient_ids.each do |recipient_id|
      recipient = InvoiceRecipient.find(recipient_id)
      used_in_source = recipient.invoices.where.not(id: invoice_ids).exists? ||
                       InvoiceChatSession.where(organization_id: source.id, invoice_recipient_id: recipient.id)
                                         .where.not(id: session_ids).exists?
      if used_in_source
        copy = recipient.dup
        copy.organization = destination
        copy.company = recipient.company_id == company.id ? company : nil
        copy.save!
        Invoice.where(id: invoice_ids, invoice_recipient_id: recipient.id).update_all(invoice_recipient_id: copy.id)
        InvoiceChatSession.where(id: session_ids, invoice_recipient_id: recipient.id).update_all(invoice_recipient_id: copy.id)
        recipient.update_columns(company_id: nil) if recipient.company_id == company.id
      else
        raise Conflict, "Recipient belongs to another company" if recipient.company_id && recipient.company_id != company.id

        recipient.update_columns(organization_id: destination.id)
      end
    end

    # Recipients used only by source invoices, including legacy company-linked
    # recipients, stay with Cornerstone after the payroll company moves.
    InvoiceRecipient.where(organization_id: source.id, company_id: company.id).update_all(company_id: nil)

    if billing_profile
      was_default = billing_profile.is_default?
      billing_profile.update_columns(organization_id: destination.id, is_default: true,
                                     legal_name: issuer_legal_name.strip)
      if was_default
        source.invoice_billing_profiles.where.not(id: billing_profile.id).order(:id).first&.update!(is_default: true)
      end
    end

    Invoice.where(id: invoice_ids).update_all(organization_id: destination.id)
    InvoiceChatSession.where(id: session_ids).update_all(organization_id: destination.id)
    [ InvoiceArtifact, InvoiceEvent, InvoicePayment, InvoiceCreditNote, InvoiceDelivery ].each do |model|
      model.where(invoice_id: invoice_ids).update_all(organization_id: destination.id)
    end
  end
end
