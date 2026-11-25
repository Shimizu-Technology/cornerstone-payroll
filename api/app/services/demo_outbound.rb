# frozen_string_literal: true

require "digest"
require "set"

# Outbound containment for demo companies. A demo company may email or invite
# only the exact addresses in DEMO_EMAIL_ALLOWLIST (private configuration,
# comma separated). Addresses are compared after strip + downcase only, so
# plus-addressed aliases (name+tag@domain) are distinct entries.
#
# Senders check at issue or enqueue and again right before delivery. Inside
# DemoOutbound.scoped(company) the mail and Clerk transports filter the final
# recipients as well, which also covers stale queued jobs and retries. A
# refused recipient is dropped silently, logged without the address and
# audited; nothing is sent to it.
module DemoOutbound
  ENV_KEY = "DEMO_EMAIL_ALLOWLIST"
  # Reserved names (RFC 2606) never deliver, so a demo record may hold them.
  NON_DELIVERING_DOMAIN = /\.(example|test|invalid)\z/
  SCOPE_KEY = :demo_outbound_company_id
  CHANNEL_KEY = :demo_outbound_channel
  # Employee app mail and sign-up steps. For a demo these go out only while
  # that demo's employee app is on, so the demo kill switch (M4-9d), which
  # turns it off, also stops every queued or retried employee notification.
  EMPLOYEE_CHANNELS = %w[
    employee_link_invite employee_link_claim employee_link_activation employee_link_bind employee_tax_form_notice
    employee_portal_notification
  ].freeze

  module_function

  def normalize(email)
    email.to_s.strip.downcase.presence
  end

  def allowlist
    ENV.fetch(ENV_KEY, "").split(",").filter_map { |entry| normalize(entry) }.to_set
  end

  def allowed?(email)
    address = normalize(email)
    address.present? && allowlist.include?(address)
  end

  # A demo contact may hold an allow-listed address or a reserved,
  # non-delivering one. Live companies are not affected.
  def contact_email_allowed?(company, email)
    return true unless company&.demo?

    address = normalize(email)
    address.nil? || allowed?(address) || address.split("@", 2).last.to_s.match?(NON_DELIVERING_DOMAIN)
  end

  # True when the recipient may be contacted for this company. A refusal is
  # logged and audited, and the caller must not send.
  def permit?(company:, email:, channel:, user: nil)
    return true unless demo_target?(company, user)

    if EMPLOYEE_CHANNELS.include?(channel.to_s) && !employee_app_open?(company&.demo? ? company : demo_company_for(user))
      refuse!(company: company || demo_company_for(user), email: email, channel: channel, user: user, reason: "employee_app_off")
      return false
    end
    return true if allowed?(email)

    refuse!(company: company || demo_company_for(user), email: email, channel: channel, user: user)
    false
  end

  # Allowed recipients only; each dropped one is refused as above.
  def filter(company:, emails:, channel:)
    Array(emails).flatten.compact.select { |email| permit?(company: company, email: email, channel: channel) }
  end

  # A login belongs to a demo when its home company is a demo, or when a
  # non-staff login is linked or assigned to one. Firm staff who merely work
  # on a demo keep their ordinary mail.
  def demo_user?(user)
    !demo_company_for(user).nil?
  end

  def demo_company_for(user)
    return if user.nil?
    return user.company if user.company&.demo?
    return if user.staff_member?

    # Read-only: which demo company, if any, a login is attached to. Callers
    # run in requests, jobs and binding paths with or without a tenant scope.
    outside_scope(-> { TenantScope.as_system(reason: "Find the demo company a login belongs to") { demo_company_lookup(user) } }) { demo_company_lookup(user) }
  end

  # Only current ties count: an expired assignment or an inactive demo
  # company never makes a login a demo login.
  def demo_company_lookup(user)
    demo = Company.demo.active
    demo.where(id: EmployeeAccountLink.where(user_id: user.id).select(:company_id))
      .or(demo.where(id: CompanyAssignment.active_access.where(user_id: user.id).select(:company_id))).order(:id).first
  end

  # Enters a scope only when none is active; scopes never nest.
  def outside_scope(enter)
    TenantScope.current ? yield : enter.call
  end

  def demo_target?(company, user)
    company&.demo? || demo_user?(user)
  end

  # Marks the code inside the block as sending for this company, so the
  # transports filter the final recipients too. A nested scope for a non-demo
  # company keeps an outer demo scope. With an employee channel, the
  # transport also rechecks, right before sending, that the demo's employee
  # app is still on (the demo kill switch may have run since enqueue).
  def scoped(company, channel: nil)
    previous = Thread.current[SCOPE_KEY]
    previous_channel = Thread.current[CHANNEL_KEY]
    if company&.demo?
      Thread.current[SCOPE_KEY] = company.id
      Thread.current[CHANNEL_KEY] = channel&.to_s
    end
    yield
  ensure
    Thread.current[SCOPE_KEY] = previous
    Thread.current[CHANNEL_KEY] = previous_channel
  end

  def scope_company
    id = Thread.current[SCOPE_KEY]
    id && Company.find_by(id: id)
  end

  # Transport check: the payload with only allowed recipients, or nil when
  # none remain (the caller then sends nothing).
  def filter_payload(payload)
    company = scope_company
    return payload unless company

    filtered = payload.dup
    %i[to cc bcc].each do |key|
      # Symbol and string keys are combined, so neither can slip past.
      values = [ filtered.delete(key), filtered.delete(key.to_s) ].flatten.compact
      next if values.empty?

      kept = filter(company: company, emails: values, channel: Thread.current[CHANNEL_KEY] || "mail_transport").uniq
      filtered[key] = kept if kept.any?
    end
    Array(filtered[:to]).any? ? filtered : nil
  end

  # Fails closed: an unreadable profile counts as off.
  def employee_app_open?(company)
    return false unless company

    CompanyFeatures.for(company).employee_portal_enabled?
  rescue StandardError => error
    Rails.logger.warn("[DemoOutbound] employee app state unavailable: #{error.class}")
    false
  end

  def refuse!(company:, email:, channel:, user: nil, reason: nil)
    address = normalize(email)
    domain = address&.split("@", 2)&.last
    digest = address && Digest::SHA256.hexdigest(address)
    Rails.logger.info("[DemoOutbound] refused channel=#{channel} company_id=#{company&.id} domain=#{domain}")
    return unless company

    actor = Current.actor || AuditActor.system_job(name)
    # Senders run in requests, jobs and system sweeps; the refusal is always
    # recorded under the demo company's own tenant scope.
    record = lambda do
      Current.set(domain_audit_recorded: nil) do
        AuditLog.record!(actor: actor, organization_id: company.organization_id, company_id: company.id,
          action: "outbound#recipient_refused", record_type: "Company", record_id: company.id,
          metadata: { channel: channel, recipient_domain: domain, recipient_digest: digest, user_id: user&.id }
            .merge(reason ? { reason: reason } : {}),
          event_category: "security")
      end
    end
    outside_scope(-> { TenantScope.with_company(company.id) { record.call } }) { record.call }
  rescue StandardError => error
    # The refusal stands even if its audit row cannot be written.
    Rails.logger.error("[DemoOutbound] refusal audit failed: #{error.class}")
  end
end
