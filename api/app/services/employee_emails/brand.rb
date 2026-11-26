# frozen_string_literal: true

module EmployeeEmails
  # The employer's look in an employee email: the name and app title the
  # employee app shows, the logo when one can be fetched over https, and a
  # button color that always carries white text at 4.5:1 (the same rule as
  # actionColorFor in web/src/employee/brand.ts).
  #
  # Only public branding is read, plus the first Help contact email as the
  # reply-to address. Help contacts are otherwise shown only to signed-in
  # employees; the recipient here is that employee.
  Brand = Data.define(:name, :app_name, :logo_url, :primary_color, :help_email)

  class Brand
    # Payroll blue, the employee app's color when a client sets none.
    FALLBACK_COLOR = "#194baa"
    # Slate-800, for buttons when the client's color is too light for white text.
    NEUTRAL_ACTION_COLOR = "#1e293b"
    MIN_TEXT_CONTRAST = 4.5
    LIGHT_LUMINANCE = 0.4
    # The API's public https origin, which serves uploaded logos. Without
    # it an uploaded logo can't be linked from an email, so the initial
    # badge shows instead.
    ASSET_ORIGIN_ENV = "PUBLIC_API_URL"

    def self.for(company)
      branding = company.branding.is_a?(Hash) ? company.branding.stringify_keys : {}
      new(
        name: TenantSubdomainRegistry.display_text(branding["display_name"], TenantSubdomainRegistry::DISPLAY_NAME_MAX) || company.name.to_s.squish,
        app_name: TenantSubdomainRegistry.display_text(branding["app_name"], TenantSubdomainRegistry::APP_NAME_MAX),
        logo_url: logo_url_for(company, branding),
        primary_color: TenantSubdomainRegistry.hex_color(branding["primary_color"]),
        help_email: help_email_for(company)
      )
    end

    # The public logo route serves an uploaded logo only while the company's
    # subdomain is live, so an uploaded logo is linked only then.
    def self.logo_url_for(company, branding)
      origin = TenantSubdomainRegistry.https_url(ENV[ASSET_ORIGIN_ENV].to_s.strip.delete_suffix("/"))
      uploaded = if origin && company.brand_logo_digest && EmployeeLinks::AppUrl.subdomain_live?(company)
        TenantSubdomainRegistry.uploaded_logo_url(company, company.subdomain_slug, origin)
      end
      uploaded || TenantSubdomainRegistry.https_url(branding["logo_url"])
    end

    def self.help_email_for(company)
      company.help_contacts.to_a.map(&:email).find do |email|
        email.present? && CompanyHelpContact::EMAIL_PATTERN.match?(email) && !email.match?(/[[:cntrl:]",]/)
      end
    end

    def self.contrast_with_white(hex)
      1.05 / (relative_luminance(hex) + 0.05)
    end

    def self.relative_luminance(hex)
      red, green, blue = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
      channel = ->(value) { value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4 }
      (0.2126 * channel.call(red)) + (0.7152 * channel.call(green)) + (0.0722 * channel.call(blue))
    end

    # The color as entered, a darker shade of it, or neutral for light colors.
    def self.action_color_for(hex)
      return hex if contrast_with_white(hex) >= MIN_TEXT_CONTRAST
      return NEUTRAL_ACTION_COLOR if relative_luminance(hex) > LIGHT_LUMINANCE

      rgb = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16).to_f }
      60.times do
        break if contrast_with_white(to_hex(rgb)) >= MIN_TEXT_CONTRAST

        rgb = rgb.map { |value| value * 0.93 }
      end
      to_hex(rgb)
    end

    def self.to_hex(rgb)
      "##{rgb.map { |value| value.round.clamp(0, 255).to_s(16).rjust(2, '0') }.join}"
    end

    # The client's own color, for the top stripe (no text sits on it).
    def decoration_color
      primary_color&.downcase || FALLBACK_COLOR
    end

    def action_color
      self.class.action_color_for(decoration_color)
    end

    def monogram
      name.to_s[/[[:alnum:]]/]&.upcase || "C"
    end

    # "MoSa's Team" when the client named the app, otherwise "the Harbor
    # Finch Kitchen employee app".
    def app_title
      app_name || "the #{name} employee app"
    end

    # The small line under the name in the header.
    def header_subtitle
      app_name || "Employee app"
    end
  end
end
