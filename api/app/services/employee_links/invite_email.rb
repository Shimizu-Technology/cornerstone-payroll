# frozen_string_literal: true

module EmployeeLinks
  # The invite email. It carries the employer's name and branding, a one-time
  # link and its expiry date, and nothing about pay. Real email stays off unless
  # PORTAL_EMAIL_NOTIFICATIONS_ENABLED=true; a skipped invite is resent later.
  module InviteEmail
    module_function

    # Returns :sent, :captured, :skipped or :failed.
    def deliver(link:, token:, path:)
      return :skipped unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

      url = AppUrl.invite_url(link.company, path: path, secret: token)
      to = link.invite_email
      return :failed unless url && to
      return :skipped unless DemoOutbound.permit?(company: link.company, email: to, channel: "employee_link_invite")

      response = DemoOutbound.scoped(link.company, channel: "employee_link_invite") do
        PortalNotifications::Transport.deliver(payload(link, url, path, to),
          idempotency_key: "employee-link-invite-#{link.id}-#{link.invite_token_digest.first(16)}")
      end
      return :skipped if response["suppressed"]

      response["captured"] || response["staging_captured"] ? :captured : :sent
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::InviteEmail] Invite email for link #{link.id} failed: #{error.class}")
      :failed
    end

    def payload(link, url, path, to)
      brand = EmployeeEmails::Brand.for(link.company)
      message(brand, url: url, path: path, expires_at: link.invite_expires_at, features: features(link.company)).payload(to: to)
    end

    # The parts of the app the employer has turned on, for the one sentence
    # about what the app is for. Unknown settings fall back to the basics.
    def features(company)
      settings = CompanyFeatures.for(company)
      %i[stubs tax_forms profile_requests].select { |feature| settings.employee_portal_feature?(feature) }
    rescue StandardError
      %i[stubs profile_requests]
    end

    def message(brand, url:, path:, expires_at:, features:)
      sign_up = path == "sign_up"
      label = sign_up ? "Set up your account" : "Sign in"
      paragraphs = [ about_line(brand.name, features) ]
      paragraphs << "You already have an employee app login. Sign in with it to add this access." unless sign_up
      EmployeeEmails::Message.new(
        brand: brand,
        subject: "You're invited to #{brand.app_title}",
        heading: "You're invited to #{brand.app_title}",
        paragraphs: paragraphs,
        action: { label: label, url: url },
        note: expiry_line(expires_at),
        preheader: "#{label} to get started. The link works once.",
        ignorable: true
      )
    end

    def about_line(employer, features)
      pay = [ ("pay stubs" if features.include?(:stubs)), ("tax forms" if features.include?(:tax_forms)) ].compact
      uses = []
      uses << "see your #{pay.join(' and ')}" if pay.any?
      uses << "keep your contact details up to date" if features.include?(:profile_requests)
      return "#{employer} invited you to its employee app." if uses.empty?

      "#{employer} invited you to its employee app, where you can #{uses.join(' and ')}."
    end

    def expiry_line(expires_at)
      return "This link works once and expires in #{EmployeeAccountLink::INVITE_LIFETIME.in_days.to_i} days." unless expires_at

      "This link works once and expires on #{EmployeeEmails::Message.guam_date(expires_at)} (Guam time)."
    end
  end
end
