# frozen_string_literal: true

module EmployeeEmails
  # Renders every employee email with made-up employers and links, for
  # design review (bin/rails employee_emails:preview). Nothing here reads
  # the database or a real company.
  module Preview
    # A small logo drawn inline, so a preview needs no network.
    SAMPLE_LOGO = "data:image/svg+xml;base64,#{Base64.strict_encode64(<<~SVG)}".freeze
      <svg xmlns="http://www.w3.org/2000/svg" width="120" height="40" viewBox="0 0 120 40"><rect width="120" height="40" rx="8" fill="#7c2d12"/><text x="60" y="26" font-family="Georgia, serif" font-size="17" fill="#fff7ed" text-anchor="middle">Kahuna Co</text></svg>
    SVG

    module_function

    def brands
      {
        badge: Brand.new(name: "Harbor Finch Kitchen", app_name: nil, logo_url: nil, primary_color: "#0f766e",
          help_email: "help@harborfinch.example.test"),
        logo: Brand.new(name: "Kahuna Coffee Example Co", app_name: "Kahuna Crew", logo_url: SAMPLE_LOGO,
          primary_color: "#c2410c", help_email: nil),
        light: Brand.new(name: "Pelican Row Bakery", app_name: nil, logo_url: nil, primary_color: "#facc15", help_email: nil)
      }
    end

    def messages
      expires_at = Time.zone.parse("2026-12-10 09:00") || Time.current
      token_url = "https://harborfinch.example.test/activate#token=PREVIEW-not-a-real-token-0123456789abcdefghij"
      {
        "invite_sign_up" => EmployeeLinks::InviteEmail.message(brands[:badge], url: token_url, path: "sign_up",
          expires_at: expires_at, features: %i[stubs tax_forms profile_requests]),
        "invite_sign_in" => EmployeeLinks::InviteEmail.message(brands[:logo], url: "https://kahuna.example.test/claim#token=PREVIEW",
          path: "claim", expires_at: expires_at, features: %i[stubs profile_requests]),
        "activation_notice" => EmployeeLinks::ActivationNoticeEmail.message(brands[:light],
          activated_at: expires_at, app_url: "https://pelicanrow.example.test"),
        "email_change_notice" => EmployeeLinks::EmailChange.message(brands[:badge]),
        "tax_form_notice" => EmployeeDocuments::TaxFormNotice.message(brands[:badge], tax_year: 2026,
          employer: "Harbor Finch Kitchen", app_url: "https://harborfinch.example.test")
      }
    end

    # Writes <name>.html and <name>.txt for each email; returns the paths.
    def write!(dir)
      FileUtils.mkdir_p(dir)
      messages.flat_map do |name, message|
        html = File.join(dir, "#{name}.html")
        text = File.join(dir, "#{name}.txt")
        payload = message.payload(to: "employee@example.test")
        headers = { "From" => Message.from_header(message.brand.name, "Payroll <noreply@example.test>"),
                    "Reply-To" => payload[:reply_to], "Subject" => payload[:subject] }.compact
        File.write(html, message.html(preview: true))
        File.write(text, "#{headers.map { |key, value| "#{key}: #{value}" }.join("\n")}\n\n#{payload[:text]}")
        [ html, text ]
      end
    end
  end
end
