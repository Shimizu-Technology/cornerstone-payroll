# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee emails" do
  let(:company) { create(:company, name: "Harbor Finch Kitchen") }
  let(:link) { Struct.new(:company, :invite_expires_at).new(company, Time.utc(2026, 12, 9, 20, 0)) }
  let(:token) { "tok3n-SECRET-abc123" }
  let(:url) { "https://harborfinch.example.test/activate#token=#{token}" }

  around do |example|
    previous = ENV.to_h.slice("RESEND_FROM_EMAIL", "MAILER_FROM_EMAIL", "PUBLIC_API_URL", "EMPLOYEE_APP_URL")
    ENV["RESEND_FROM_EMAIL"] = "Cornerstone Payroll <noreply@payroll.example.test>"
    ENV["EMPLOYEE_APP_URL"] = "https://employees.example.test"
    ENV.delete("PUBLIC_API_URL")
    example.run
  ensure
    %w[RESEND_FROM_EMAIL MAILER_FROM_EMAIL PUBLIC_API_URL EMPLOYEE_APP_URL].each { |key| ENV[key] = previous[key] }
  end

  def invite(path: "sign_up", to: "kai@example.net")
    EmployeeLinks::InviteEmail.payload(link, url, path, to)
  end

  # The text inside <h1>.
  def heading_of(html)
    html[%r{<h1[^>]*>(.*?)</h1>}m, 1]
  end

  describe "sender" do
    it "sends as the employer via Cornerstone Payroll from the configured address only" do
      expect(invite[:from]).to eq(%("Harbor Finch Kitchen via Cornerstone Payroll" <noreply@payroll.example.test>))

      ENV["RESEND_FROM_EMAIL"] = "payroll@example.test"
      expect(invite[:from]).to eq(%("Harbor Finch Kitchen via Cornerstone Payroll" <payroll@example.test>))
    end

    it "can't be used to add a header or a second address" do
      company.update!(name: %(Evil" <x@y>\r\nBcc: victim@example.net))
      from = invite[:from]

      expect(from).not_to match(/[\r\n]/)
      expect(from.scan(/[<>"]/).join).to eq(%(""<>))
      expect(Mail::Address.new(from).address).to eq("noreply@payroll.example.test")
      expect(Mail::Address.new(from).display_name).to start_with("Evil x@y Bcc: victim@example.net")
    end

    it "neutralizes control, format and BiDi characters and encoded-words in the From name and the subject" do
      hostile = "Harbor\u2028Finch\u0000 \u202Eeman\u200B =?UTF-8?B?UGF5cm9sbCBTdXBwb3J0?= Kitchen\r\nBcc: x@y.test"
      from = EmployeeEmails::Message.from_header(hostile)
      brand = EmployeeEmails::Brand.new(name: hostile, app_name: nil, logo_url: nil, primary_color: nil, help_email: nil)
      subject = EmployeeEmails::Message.new(brand: brand, subject: "Hi #{hostile}", heading: "h", paragraphs: []).payload(to: "kai@example.net")[:subject]

      [ from, subject ].each do |header|
        expect(header).not_to match(/[\p{Cc}\p{Cf}\u2028\u2029]/)
        expect(header).not_to include("=?")
      end
      expect(Mail::Address.new(from).address).to eq("noreply@payroll.example.test")
      expect(subject).to start_with("Hi Harbor Finch eman")
    end

    it "caps a long employer name and subject with plain dots" do
      expect(EmployeeEmails::Message.header_name("A" * 30 + " " + "B" * 40)).to eq("#{'A' * 30}...")
      long = EmployeeEmails::Message.new(brand: EmployeeEmails::Brand.for(company), subject: "word " * 60, heading: "h", paragraphs: [])
      expect(long.subject.length).to be <= EmployeeEmails::Message::SUBJECT_MAX
      expect(long.subject).to end_with("...")
    end

    it "caps a long employer name" do
      expect(EmployeeEmails::Message.header_name("A" * 30 + " " + "B" * 40).length).to be <= EmployeeEmails::Message::SENDER_NAME_MAX
    end

    it "omits a reply-to address that isn't a plain, valid address" do
      contact = company.help_contacts.create!(position: 1, name: "Front desk", email: "desk@harborfinch.example.test")
      [ "a..b@harborfinch.example.test", "desk@harborfinch.example.test\u2028Bcc: x@y.test", "Desk <desk@harborfinch.example.test>" ].each do |bad|
        contact.update_columns(email: bad)
        company.help_contacts.reset
        expect(invite).not_to have_key(:reply_to), bad
      end
    end

    it "never puts an address outside the demo allow-list in a demo company's reply-to" do
      demo = create_demo_company(organization: create(:organization), name: "Demo Kitchen", fixture_key: "demo-kitchen")
      demo.help_contacts.create!(position: 1, name: "Real person", email: "real.person@harborfinch.example.com")
      previous = ENV.fetch(DemoOutbound::ENV_KEY, nil)
      ENV[DemoOutbound::ENV_KEY] = "allowed@demo-mail.example"
      expect(EmployeeEmails::Brand.for(demo).help_email).to be_nil

      demo.help_contacts.create!(position: 2, name: "Demo desk", email: "allowed@demo-mail.example")
      demo.help_contacts.reset
      expect(EmployeeEmails::Brand.for(demo).help_email).to eq("allowed@demo-mail.example")

      filtered = DemoOutbound.scoped(demo) do
        DemoOutbound.filter_payload({ to: "allowed@demo-mail.example", reply_to: "real.person@harborfinch.example.com" })
      end
      expect(filtered).not_to have_key(:reply_to)
      kept = DemoOutbound.scoped(demo) do
        DemoOutbound.filter_payload({ to: "allowed@demo-mail.example", "reply_to" => "allowed@demo-mail.example" })
      end
      expect(kept[:reply_to]).to eq([ "allowed@demo-mail.example" ])
    ensure
      ENV[DemoOutbound::ENV_KEY] = previous
    end

    it "replies to the first Help contact with an email, and to no one without one" do
      expect(invite).not_to have_key(:reply_to)

      company.help_contacts.create!(position: 1, name: "Front desk", phone: "671-555-0100")
      company.help_contacts.create!(position: 2, name: "Lani Example", email: "Help@HarborFinch.example.test")
      expect(invite[:reply_to]).to eq("help@harborfinch.example.test")
    end
  end

  describe EmployeeLinks::InviteEmail do
    it "names the employer, buttons the link and gives the expiry date in Guam time" do
      mail = invite

      expect(mail[:subject]).to eq("You're invited to the Harbor Finch Kitchen employee app")
      expect(heading_of(mail[:html])).to eq("You&#39;re invited to the Harbor Finch Kitchen employee app")
      expect(heading_of(mail[:html])).not_to include(token)
      expect(mail[:html]).to include(%(<a href="#{url}" target="_blank" rel="noopener" style="display:inline-block;))
      expect(mail[:html]).to include(">Set up your account</a>")
      expect(mail[:html]).to include("This link works once and expires on December 10, 2026 (Guam time).")
      expect(mail[:html]).to include("Button not working? Copy this link into your browser:")
      expect(mail[:html]).to include("Sent by Cornerstone Payroll on behalf of Harbor Finch Kitchen")
      expect(mail[:html]).to include("If you weren&#39;t expecting it, you can ignore this email.")
    end

    it "has a plain-text part with the link on its own line" do
      lines = invite[:text].lines.map(&:chomp)

      expect(lines.first).to eq("You're invited to the Harbor Finch Kitchen employee app")
      expect(lines).to include("Set up your account: #{url}")
      expect(lines).to include("This link works once and expires on December 10, 2026 (Guam time).")
      expect(lines).to include("Sent by Cornerstone Payroll on behalf of Harbor Finch Kitchen")
    end

    it "asks someone with a login to sign in" do
      mail = invite(path: "claim")

      expect(mail[:html]).to include(">Sign in</a>")
      expect(mail[:html]).not_to include("Set up your account")
      expect(mail[:text].lines.map(&:chomp)).to include("Sign in: #{url}")
    end

    it "escapes the employer's name everywhere it appears" do
      company.update!(name: %(<script>alert("x")</script> & Co))
      mail = invite

      expect(mail[:html]).not_to include("<script>")
      expect(mail[:html]).to include("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; Co")
    end

    it "mentions only the parts of the app the employer has on" do
      brand = EmployeeEmails::Brand.for(company)
      all = described_class.message(brand, url: url, path: "sign_up", expires_at: nil, features: %i[stubs tax_forms profile_requests])
      stubs = described_class.message(brand, url: url, path: "sign_up", expires_at: nil, features: %i[stubs])
      stubs_and_contact = described_class.message(brand, url: url, path: "sign_up", expires_at: nil, features: %i[stubs profile_requests])

      expect(all.paragraphs.first).to eq("Harbor Finch Kitchen invited you to its employee app, where you can see your " \
        "pay stubs and tax forms, and keep your contact details up to date.")
      expect(stubs.paragraphs.first).to eq("Harbor Finch Kitchen invited you to its employee app, where you can see your pay stubs.")
      expect(stubs_and_contact.paragraphs.first).to eq("Harbor Finch Kitchen invited you to its employee app, where you can see your " \
        "pay stubs and keep your contact details up to date.")
      expect(stubs.note).to eq("This link works once and expires in 14 days.")
    end

    it "keeps the token out of the subject, heading and inbox preview" do
      mail = invite
      preheader = mail[:html][%r{<div style="display:none;[^>]*>(.*?)</div>}m, 1]

      expect(preheader).to start_with("Set up your account to get started.")
      [ mail[:subject], heading_of(mail[:html]), preheader ].each { |part| expect(part).not_to include(token) }
    end

    it "renders the reactivate path as a sign-in" do
      mail = invite(path: "reactivate")

      expect(mail[:html]).to include(">Sign in</a>", "You already have an employee app login.")
      expect(mail[:text].lines.map(&:chomp)).to include("Sign in: #{url}")
    end

    it "has an Outlook button and a fixed-width card for Outlook" do
      html = invite[:html]

      expect(html).to include(%(<v:roundrect xmlns:v="urn:schemas-microsoft-com:vml"), %(href="#{url}"), "<!--[if !mso]><!-->")
      expect(html).to include(%(<!--[if mso]><table role="presentation" width="520" align="center"))
    end

    it "names no features when the employer's settings can't be read" do
      allow(CompanyFeatures).to receive(:for).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect(described_class.features(company)).to eq([])
      expect(invite[:text]).to include("Harbor Finch Kitchen invited you to its employee app.\n")
    end

    it "carries nothing about pay" do
      expect(invite.values_at(:subject, :text, :html).join).not_to match(/\$\d|SSN|salary/i)
    end
  end

  describe EmployeeEmails::Brand do
    it "uses the employee app's display name, app name and color" do
      company.update!(branding: { "display_name" => "Harbor Finch", "app_name" => "Finch Crew", "primary_color" => "#0F766E" })
      mail = invite

      expect(mail[:subject]).to eq("You're invited to Finch Crew")
      expect(mail[:from]).to start_with(%("Harbor Finch via Cornerstone Payroll"))
      expect(mail[:html]).to include('bgcolor="#0f766e"')
    end

    def uploaded_logo!(slug: "harborfinch")
      company.update_columns(subdomain_slug: slug)
      allow(company).to receive_messages(brand_logo_digest: "0123456789abcdef", brand_logo_extension: "png")
      allow(EmployeeLinks::AppUrl).to receive(:subdomain_live?).with(company).and_return(true)
    end

    it "shows the uploaded logo in a white cell, and an initial badge without one" do
      expect(invite[:html]).to include(">H</td>")
      expect(invite[:html]).not_to include("<img")

      uploaded_logo!
      ENV["PUBLIC_API_URL"] = "https://employee-api.example.com"
      html = invite[:html]
      expect(html).to include(%(<td bgcolor="#ffffff" style="background-color:#ffffff;padding:4px;border-radius:8px;"><img ) +
        %(src="https://employee-api.example.com/api/v1/public/tenant_branding/logo/harborfinch/0123456789abcdef.png" alt="Harbor Finch Kitchen" height="40"))
      expect(html).not_to include(">H</td>")
    end

    it "links an uploaded logo only through our own route, while the subdomain is live and the API's address is set" do
      uploaded_logo!
      expect(EmployeeEmails::Brand.for(company).logo_url).to be_nil

      ENV["PUBLIC_API_URL"] = "https://Employee-API.example.com/"
      expect(EmployeeEmails::Brand.for(company).logo_url)
        .to eq("https://employee-api.example.com/api/v1/public/tenant_branding/logo/harborfinch/0123456789abcdef.png")

      allow(EmployeeLinks::AppUrl).to receive(:subdomain_live?).with(company).and_return(false)
      expect(EmployeeEmails::Brand.for(company).logo_url).to be_nil
    end

    it "accepts only a bare https origin for the API's address" do
      uploaded_logo!
      [ "http://employee-api.example.com", "https://employee-api.example.com/api", "https://employee-api.example.com:8443",
        "https://user@employee-api.example.com", "https://employee-api.example.com?x=1", "https://localhost",
        "javascript:alert(1)", "not a url" ].each do |value|
        ENV["PUBLIC_API_URL"] = value
        expect(EmployeeEmails::Brand.for(company).logo_url).to be_nil, value
      end
    end

    it "never uses a client-entered logo URL, even when an upload can't be linked" do
      company.update!(branding: { "logo_url" => "https://tracker.example.com/pixel.png" })
      expect(invite[:html]).not_to include("<img")

      uploaded_logo!
      expect(invite[:html]).not_to include("tracker.example.com")
    end

    it "draws only an https logo, and a data: logo only in a preview" do
      base = EmployeeEmails::Brand.new(name: "Harbor Finch Kitchen", app_name: nil, logo_url: nil, primary_color: nil, help_email: nil)
      draw = ->(logo, preview: false) { EmployeeEmails::Message.new(brand: base.with(logo_url: logo), subject: "s", heading: "h", paragraphs: []).html(preview: preview) }

      [ "http://cdn.example.com/a.png", "javascript:alert(1)", "data:image/png;base64,AAAA", "//cdn.example.com/a.png",
        "https://localhost/a.png" ].each { |logo| expect(draw.call(logo)).not_to include("<img"), logo }
      expect(draw.call("https://cdn.example.com/a.png")).to include(%(<img src="https://cdn.example.com/a.png"))
      expect(draw.call("data:image/png;base64,AAAA", preview: true)).to include(%(<img src="data:image/png;base64,AAAA"))
      expect(draw.call("javascript:alert(1)", preview: true)).not_to include("<img")
    end

    it "can't be used to break out of a style attribute, and never crashes on a short color" do
      hostile = EmployeeEmails::Brand.new(name: "Harbor Finch Kitchen", app_name: nil, logo_url: nil, help_email: nil,
        primary_color: "#000000;background-image:url(https://tracker.example.com/x)")
      html = EmployeeEmails::Message.new(brand: hostile, subject: "s", heading: "h", paragraphs: [], action: { label: "Go", url: url }).html

      expect(html).not_to include("background-image", "tracker.example.com")
      expect(html).to include('bgcolor="#194baa"')
      expect(hostile.with(primary_color: "#fff").action_color).to eq("#194baa")
      expect(described_class.action_color_for("#fff")).to eq("#194baa")
      expect(described_class.action_color_for(nil)).to eq("#194baa")
    end

    it "escapes the client's app name" do
      company.update!(branding: { "app_name" => %(Finch & Co's "Crew") })
      mail = invite

      expect(mail[:html]).to include("Finch &amp; Co&#39;s &quot;Crew&quot;")
      expect(mail[:html]).not_to include(%(Finch & Co's "Crew"))
    end

    it "keeps white button text readable on any brand color" do
      %w[#facc15 #ffffff #22c55e #0ea5e9 #ef4444 #194baa #000000 #a3a3a3].each do |color|
        action = described_class.action_color_for(color)
        expect(described_class.contrast_with_white(action)).to be >= 4.5, "#{color} -> #{action}"
      end
      expect(described_class.action_color_for("#194baa")).to eq("#194baa")
      expect(described_class.action_color_for("#facc15")).to eq(described_class::NEUTRAL_ACTION_COLOR)
    end
  end

  describe EmployeeLinks::ActivationNoticeEmail do
    it "is a branded security notice with the date in Guam time" do
      link = Struct.new(:company).new(company)
      mail = described_class.payload(link, "kai@example.net", Time.utc(2026, 11, 25, 20, 0))

      expect(mail).to include(to: "kai@example.net", subject: "Your Harbor Finch Kitchen employee app account was set up",
        from: %("Harbor Finch Kitchen via Cornerstone Payroll" <noreply@payroll.example.test>))
      expect(mail[:html]).to include("Your Harbor Finch Kitchen employee app account was set up on November 26, 2026 (Guam time).")
      expect(mail[:html]).to include(%(<a href="https://employees.example.test" ), ">Open the employee app</a>")
      expect(mail[:html]).not_to include("you can ignore this email")
      expect(mail[:text].lines.map(&:chomp)).to include("Open the employee app: https://employees.example.test",
        "If this wasn't you, contact Harbor Finch Kitchen or Cornerstone right away.")
    end
  end

  describe EmployeeDocuments::TaxFormNotice do
    let(:document) { Struct.new(:company, :tax_year).new(company, 2026) }

    it "keeps the required subject and sentences, and opens the tax forms page rather than a document" do
      mail = described_class.payload(document, "kai@example.net")

      expect(mail[:subject]).to eq("IMPORTANT TAX RETURN DOCUMENT AVAILABLE")
      expect(mail[:text].lines.map(&:chomp)).to include(
        "Your 2026 Form W-2GU from Harbor Finch Kitchen is now available in your employee app.",
        "Sign in to view or download it: https://employees.example.test/taxes",
        "You'll also get a paper copy, the same way as other years. If you weren't expecting this email, contact Harbor Finch Kitchen."
      )
      expect(mail[:html]).to include(
        "Your 2026 Form W-2GU from Harbor Finch Kitchen is now available in your employee app.",
        "Sign in to view or download it.",
        "You&#39;ll also get a paper copy, the same way as other years. If you weren&#39;t expecting this email, contact Harbor Finch Kitchen.",
        %(<a href="https://employees.example.test/taxes" ), ">Open the employee app</a>"
      )
      expect(mail[:html].scan(/href="([^"]+)"/).flatten.uniq).to eq([ "https://employees.example.test/taxes" ])
    end

    it "names the legal employer in the required sentences even when the app shows another name" do
      company.update!(branding: { "display_name" => "Harbor Finch" })
      mail = described_class.payload(document, "kai@example.net")

      expect(mail[:text]).to include("Your 2026 Form W-2GU from Harbor Finch Kitchen is now available in your employee app.",
        "If you weren't expecting this email, contact Harbor Finch Kitchen.")
      expect(mail[:from]).to start_with(%("Harbor Finch via Cornerstone Payroll"))
    end

    it "still says where to look when the app has no address" do
      ENV["EMPLOYEE_APP_URL"] = nil
      mail = described_class.payload(document, "kai@example.net")

      expect(mail[:text]).to include("Sign in to your employee app to view or download it.")
      expect(mail[:html]).not_to include("<a ")
    end
  end

  describe EmployeeEmails::Preview do
    it "writes every email with made-up data" do
      Dir.mktmpdir do |dir|
        paths = described_class.write!(dir)

        expect(paths.map { |path| File.basename(path) }).to include("invite_sign_up.html", "invite_sign_in.txt",
          "activation_notice.html", "tax_form_notice.html")
        expect(File.read(File.join(dir, "invite_sign_up.html"))).to include("Harbor Finch Kitchen", ">Set up your account</a>")
        expect(File.read(File.join(dir, "invite_sign_up.txt"))).to include("Reply-To: help@harborfinch.example.test")
        expect(File.read(File.join(dir, "invite_sign_in.html"))).to include('<img src="data:image/svg+xml;base64,')
      end
    end
  end
end
