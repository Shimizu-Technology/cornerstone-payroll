# frozen_string_literal: true

# The employee app's branding and Help contacts for the selected company.
# Shared by Cornerstone staff (admin namespace, client administration for the
# company) and the client's own users (client namespace, access to the
# company). Each includer defines `revalidate_settings_write_access!`, which
# runs inside the company lock.
#
# Every change commits with its audit row. Help contacts are never part of the
# public tenant branding response.
module EmployeeAppSettingsActions
  extend ActiveSupport::Concern

  class AuditWriteFailed < StandardError; end

  BRANDING_FIELDS = %w[display_name app_name primary_color accent_color show_main_phone].freeze
  HELP_CONTACT_FIELDS = %w[name role phone email text_ok].freeze

  included do
    before_action :reject_closed_practice_copy, except: %i[show logo]
    rescue_from AuditWriteFailed do
      render json: { error: "Your changes weren't saved because the change history couldn't be written. Try again." }, status: :internal_server_error
    end
  end

  def show
    render json: { data: settings_payload }
  end

  # PATCH branding: display name, Home Screen name, colors and the main-phone
  # switch. Blank text and colors clear the value.
  def update_branding
    attributes = params.require(:branding).permit(*BRANDING_FIELDS).to_h
    skip_default_audit_log!
    errors = nil
    current_company.with_lock do
      revalidate_settings_write_access!
      before = branding_values(current_company)
      branding = current_company.branding.is_a?(Hash) ? current_company.branding.stringify_keys : {}
      attributes.each do |key, value|
        normalized = normalize_branding_value(key, value)
        normalized.nil? ? branding.delete(key) : branding[key] = normalized
      end
      current_company.branding = branding
      unless current_company.save
        errors = current_company.errors.full_messages
        raise ActiveRecord::Rollback
      end
      record_settings_audit!("employee_app_settings#update_branding", before, branding_values(current_company))
    end
    return render json: { error: "Check the branding fields", details: errors }, status: :unprocessable_entity if errors

    render json: { data: settings_payload }
  end

  # POST logo (multipart `file`): replaces the logo. Every upload has its
  # own storage key, so this request only ever deletes the exact object it
  # replaced, after the change commits, or its own object if the save fails.
  # A failed delete is logged and never undoes the save.
  def upload_logo
    skip_default_audit_log!
    storage = TenantLogoStorageService.new
    stored = storage.store!(company: current_company, file: params[:file])
    previous_key = nil
    committed = false
    begin
      current_company.with_lock do
        revalidate_settings_write_access!
        before = logo_values(current_company)
        previous_key = current_company.brand_logo_storage_key
        current_company.update!(stored)
        record_settings_audit!("employee_app_settings#upload_logo", before, logo_values(current_company))
      end
      committed = true
    ensure
      storage.delete_object(stored[:brand_logo_storage_key]) unless committed
    end
    storage.delete_object(previous_key) if previous_key

    render json: { data: settings_payload }
  rescue TenantLogoStorageService::InvalidLogo => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def remove_logo
    skip_default_audit_log!
    previous_key = nil
    current_company.with_lock do
      revalidate_settings_write_access!
      before = logo_values(current_company)
      previous_key = current_company.brand_logo_storage_key
      branding = current_company.branding.is_a?(Hash) ? current_company.branding.except("logo_url") : {}
      current_company.update!(brand_logo_storage_key: nil, brand_logo_content_type: nil, brand_logo_sha256: nil,
                              brand_logo_byte_size: nil, branding: branding)
      record_settings_audit!("employee_app_settings#remove_logo", before, logo_values(current_company))
    end
    TenantLogoStorageService.new.delete_object(previous_key) if previous_key

    render json: { data: settings_payload }
  end

  # GET logo: the stored logo for the settings preview, before the subdomain
  # is on. Signed-in and company-scoped, unlike the public logo route.
  def logo
    # A logo isn't a document; viewing the preview isn't audited.
    skip_default_audit_log!
    bytes = current_company.brand_logo_storage_key && TenantLogoStorageService.new.download(current_company)
    return head :not_found unless bytes

    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox"
    send_data bytes, type: current_company.brand_logo_content_type, disposition: "inline"
  end

  # PUT help_contacts: replaces the whole list, in the order given.
  def update_help_contacts
    raw = params.fetch(:help_contacts, [])
    raw = [] if raw.blank?
    unless raw.is_a?(Array) && raw.all? { |entry| entry.is_a?(ActionController::Parameters) }
      return render json: { error: "Send help_contacts as a list" }, status: :unprocessable_entity
    end
    if raw.size > CompanyHelpContact::MAX_CONTACTS
      return render json: { error: "Add up to #{CompanyHelpContact::MAX_CONTACTS} Help contacts" }, status: :unprocessable_entity
    end

    entries = raw.map { |entry| entry.permit(*HELP_CONTACT_FIELDS).to_h }
    skip_default_audit_log!
    errors = nil
    current_company.with_lock do
      revalidate_settings_write_access!
      before = help_contact_values(current_company)
      current_company.help_contacts.delete_all
      contacts = entries.each_with_index.map do |entry, index|
        current_company.help_contacts.build(entry.merge("position" => index + 1, "text_ok" => ActiveModel::Type::Boolean.new.cast(entry["text_ok"]) || false))
      end
      invalid = contacts.each_with_index.reject { |contact, _| contact.valid? }
      if invalid.any?
        errors = invalid.to_h { |contact, index| [ index, contact.errors.full_messages ] }
        raise ActiveRecord::Rollback
      end
      contacts.each(&:save!)
      current_company.help_contacts.reset
      record_settings_audit!("employee_app_settings#update_help_contacts", before, help_contact_values(current_company))
    end
    if errors
      current_company.help_contacts.reset
      return render json: { error: "Check the Help contacts", details: { help_contacts: errors } }, status: :unprocessable_entity
    end

    render json: { data: settings_payload }
  end

  private

  def reject_closed_practice_copy
    return unless current_company&.test_workspace_read_only?

    render json: { error: "This practice copy is read-only. Your changes were not saved." }, status: :forbidden
  end

  def normalize_branding_value(key, value)
    case key
    when "show_main_phone"
      # Shown unless turned off; store only the "off" choice.
      ActiveModel::Type::Boolean.new.cast(value) == false ? false : nil
    when "primary_color", "accent_color"
      value.to_s.strip.downcase.presence
    else
      value.to_s.squish.presence
    end
  end

  def branding_values(company)
    values = company.branding.is_a?(Hash) ? company.branding.stringify_keys : {}
    values.slice(*BRANDING_FIELDS, "logo_url")
  end

  # Includes a legacy external logo URL, so removing one is audited too.
  def logo_values(company)
    branding = company.branding.is_a?(Hash) ? company.branding.stringify_keys : {}
    { "logo_sha256" => company.brand_logo_sha256, "logo_content_type" => company.brand_logo_content_type,
      "logo_byte_size" => company.brand_logo_byte_size, "logo_url" => branding["logo_url"] }
  end

  def help_contact_values(company)
    { "help_contacts" => company.help_contacts.reload.map { |contact| contact.as_help_json.stringify_keys } }
  end

  def record_settings_audit!(action, before, after)
    changed = (before.keys | after.keys).select { |key| before[key] != after[key] }
    return if changed.empty?

    AuditLog.record!(
      user: current_user,
      company_id: current_company.id,
      action: action,
      record_type: "companies",
      record_id: current_company.id,
      subject_name: current_company.name,
      metadata: {
        changed_fields: changed,
        before_values: before.slice(*changed),
        after_values: after.slice(*changed)
      },
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  rescue StandardError => e
    Rails.logger.error("[EmployeeAppSettings] Audit log failed; rolling back #{action}: #{e.class}")
    raise AuditWriteFailed, e.message
  end

  def settings_payload
    company = current_company
    branding = company.branding.is_a?(Hash) ? company.branding.stringify_keys : {}
    contacts = company.help_contacts.to_a
    {
      company_id: company.id,
      company_name: company.name,
      branding: {
        display_name: branding["display_name"],
        app_name: branding["app_name"],
        primary_color: branding["primary_color"],
        accent_color: branding["accent_color"],
        show_main_phone: branding["show_main_phone"] != false,
        logo: (company.brand_logo_digest && {
          content_type: company.brand_logo_content_type,
          byte_size: company.brand_logo_byte_size,
          digest: company.brand_logo_digest
        }),
        external_logo_url: TenantSubdomainRegistry.https_url(branding["logo_url"])
      },
      main_phone: company.phone.to_s.strip.presence,
      # How paper W-2s reach employees (M4-5); only Cornerstone staff change it.
      w2_delivery: company.w2_delivery,
      subdomain: {
        slug: company.subdomain_slug,
        host: company.subdomain_slug && "#{company.subdomain_slug}.#{TenantSubdomainRegistry::ROOT_DOMAIN}"
      },
      help_contacts: contacts.map(&:as_help_json),
      max_help_contacts: CompanyHelpContact::MAX_CONTACTS,
      logo_limits: { max_bytes: TenantLogoStorageService::MAX_BYTES, content_types: Company::BRAND_LOGO_EXTENSIONS.keys }
    }
  end
end
