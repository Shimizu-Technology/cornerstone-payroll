# frozen_string_literal: true

require "cgi"

module EmployeeEmails
  # The shared layout for emails to employees: the employer's header, one
  # heading, a few short paragraphs, one button and a footer saying who sent
  # it. Table-based with inline styles so Gmail, Apple Mail and Outlook draw
  # it the same, and a plain-text part with the same content.
  #
  # Employee emails never carry pay amounts, SSNs or anything else private;
  # callers pass only the employer's name, dates and app links.
  class Message
    PRODUCT = "Cornerstone Payroll"
    SENDER_NAME_MAX = 50
    SUBJECT_MAX = 150
    # Control and format characters (CR/LF, NUL, BiDi overrides such as
    # U+202E, zero-width characters) and the Unicode line separators.
    UNSAFE_HEADER_CHARACTERS = /[\p{Cc}\p{Cf}\u2028\u2029]/
    GUAM_TIME_ZONE = "Pacific/Guam"

    INK = "#0f172a"
    BODY_TEXT = "#334155"
    MUTED_TEXT = "#64748b"
    PAGE_BACKGROUND = "#f1f5f9"
    BORDER = "#e2e8f0"
    FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

    attr_reader :brand, :subject, :heading, :paragraphs, :action, :note, :closing, :preheader

    # action: { label:, url: } draws the button. lead: an HTML-only sentence
    # just above it. text_line: the plain-text line, "<label>: <url>" if unset.
    def initialize(brand:, subject:, heading:, paragraphs:, action: nil, note: nil, closing: [], preheader: nil, ignorable: false)
      @brand = brand
      @subject = self.class.header_text(subject, max: SUBJECT_MAX)
      @heading = heading
      @paragraphs = paragraphs
      @action = action
      @note = note
      @closing = closing
      @preheader = preheader
      @ignorable = ignorable
    end

    # "Harbor Finch Kitchen via Cornerstone Payroll" <payroll@example.com>.
    # The configured address may already carry a display name; only its
    # address is kept.
    def self.from_header(employer, configured = PortalNotifications::Transport.from_email)
      address = sender_address(configured)
      return configured unless address

      name = header_name(employer)
      name ? %("#{name} via #{PRODUCT}" <#{address}>) : %("#{PRODUCT}" <#{address}>)
    end

    def self.sender_address(configured)
      address = Mail::Address.new(configured.to_s.strip).address
      address if address.present? && address.match?(/\A[^\s@<>",]+@[^\s@<>",]+\z/)
    rescue Mail::Field::ParseError
      nil
    end

    # Safe inside a quoted display name: no quotes, backslashes or angle
    # brackets, on top of header_text.
    def self.header_name(value)
      header_text(value.to_s.gsub(/["\\<>]/, " "), max: SENDER_NAME_MAX)
    end

    # Text for a header (display name or subject): one line, no control or
    # format characters, no RFC 2047 encoded-word ("=?UTF-8?B?...?=") that a
    # mail client would decode into other text, and a length cap.
    def self.header_text(value, max:)
      text = value.to_s.gsub(UNSAFE_HEADER_CHARACTERS, " ").gsub("=?", "= ?").squish
      text = text.truncate(max, omission: "...", separator: " ") if text.length > max
      text.presence
    end

    def self.guam_date(time)
      time.in_time_zone(GUAM_TIME_ZONE).strftime("%B %-d, %Y")
    end

    def payload(to:)
      { from: self.class.from_header(brand.name), to: to, subject: subject, text: text, html: html, reply_to: brand.help_email }.compact
    end

    def footer_lines
      reason = "You're getting this because #{brand.name} uses #{PRODUCT} for payroll."
      reason += " If you weren't expecting it, you can ignore this email." if @ignorable
      [ reason, "Sent by #{PRODUCT} on behalf of #{brand.name}" ]
    end

    def text
      action_line = (action[:text_line] || "#{action[:label]}: #{action[:url]}" if action)
      blocks = [ heading, *paragraphs, action_line, note, *closing, footer_lines.join("\n") ]
      "#{blocks.compact.join("\n\n")}\n"
    end

    # preview: true also draws a data: logo, which only previews use.
    def html(preview: false)
      <<~HTML
        <!doctype html>
        <html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="color-scheme" content="light">
            <meta name="supported-color-schemes" content="light">
            <title>#{h(subject)}</title>
            <!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><![endif]-->
          </head>
          <body style="margin:0;padding:0;background-color:#{PAGE_BACKGROUND};-webkit-text-size-adjust:100%;">
            #{preheader_html}
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#{PAGE_BACKGROUND}" style="background-color:#{PAGE_BACKGROUND};">
              <tr>
                <td align="center" style="padding:32px 12px;">
                  <!--[if mso]><table role="presentation" width="520" align="center" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#ffffff" style="max-width:520px;background-color:#ffffff;border:1px solid #{BORDER};border-radius:12px;">
                    <tr><td height="4" bgcolor="#{h(brand.decoration_color)}" style="height:4px;background-color:#{h(brand.decoration_color)};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
                    <tr>
                      <td style="padding:24px 28px 0 28px;">
                        #{header_html(preview)}
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:24px 28px 0 28px;font-family:#{FONT};">
                        <h1 style="margin:0;font-family:#{FONT};font-size:22px;line-height:1.35;font-weight:700;color:#{INK};">#{h(heading)}</h1>
                      </td>
                    </tr>
                    #{paragraphs_html(paragraphs, top: 12)}
                    #{action_html}
                    #{paragraphs_html(closing, top: 20)}
                    <tr>
                      <td style="padding:28px 28px 28px 28px;">
                        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td height="1" bgcolor="#{BORDER}" style="height:1px;background-color:#{BORDER};font-size:0;line-height:0;">&nbsp;</td></tr></table>
                        #{footer_html}
                      </td>
                    </tr>
                  </table>
                  <!--[if mso]></td></tr></table><![endif]-->
                </td>
              </tr>
            </table>
          </body>
        </html>
      HTML
    end

    private

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    # Inbox preview text; hidden in the opened email.
    def preheader_html
      return "" unless preheader

      %(<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:#{PAGE_BACKGROUND};opacity:0;">#{h(preheader)}#{'&zwnj;&nbsp;' * 40}</div>)
    end

    # Only an https logo, or a data: one in a preview. The white cell keeps a
    # dark, transparent logo visible when a mail app darkens the email.
    def logo_src(preview)
      url = brand.logo_url.to_s
      return url if url.start_with?("https://") && TenantSubdomainRegistry.https_url(url)

      url if preview && url.start_with?("data:image/")
    end

    def header_html(preview)
      src = logo_src(preview)
      mark = if src
        <<~LOGO.strip
          <table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr><td bgcolor="#ffffff" style="background-color:#ffffff;padding:4px;border-radius:8px;"><img src="#{h(src)}" alt="#{h(brand.name)}" height="40" style="display:block;height:40px;width:auto;max-width:160px;border:0;outline:none;text-decoration:none;"></td></tr></table>
        LOGO
      else
        <<~BADGE.strip
          <table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr><td width="40" height="40" align="center" valign="middle" bgcolor="#{h(brand.action_color)}" style="width:40px;height:40px;background-color:#{h(brand.action_color)};border-radius:10px;font-family:#{FONT};font-size:18px;line-height:40px;font-weight:700;color:#ffffff;">#{h(brand.monogram)}</td></tr></table>
        BADGE
      end
      <<~HEADER.strip
        <table role="presentation" cellspacing="0" cellpadding="0" border="0">
          <tr>
            <td valign="middle" style="padding-right:12px;">#{mark}</td>
            <td valign="middle" style="font-family:#{FONT};">
              <div style="font-size:16px;line-height:1.3;font-weight:700;color:#{INK};">#{h(brand.name)}</div>
              <div style="font-size:13px;line-height:1.4;color:#{MUTED_TEXT};">#{h(brand.header_subtitle)}</div>
            </td>
          </tr>
        </table>
      HEADER
    end

    def paragraphs_html(lines, top:)
      lines.each_with_index.map do |line, index|
        <<~ROW.strip
          <tr><td style="padding:#{index.zero? ? top : 12}px 28px 0 28px;font-family:#{FONT};font-size:16px;line-height:1.6;color:#{BODY_TEXT};">#{h(line)}</td></tr>
        ROW
      end.join("\n")
    end

    def action_html
      return "" unless action

      color = h(brand.action_color)
      url = h(action[:url])
      rows = []
      rows << paragraphs_html([ action[:lead] ], top: 12) if action[:lead]
      rows << <<~BUTTON.strip
        <tr>
          <td style="padding:24px 28px 0 28px;">
            <!--[if mso]>
            <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="#{url}" style="height:48px;v-text-anchor:middle;width:#{button_width}px;" arcsize="17%" stroke="f" fillcolor="#{color}">
              <w:anchorlock/>
              <center style="color:#ffffff;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;">#{h(action[:label])}</center>
            </v:roundrect>
            <![endif]-->
            <!--[if !mso]><!-->
            <table role="presentation" cellspacing="0" cellpadding="0" border="0">
              <tr>
                <td align="center" bgcolor="#{color}" style="background-color:#{color};border-radius:8px;">
                  <a href="#{url}" target="_blank" rel="noopener" style="display:inline-block;padding:14px 28px;border:1px solid #{color};border-radius:8px;font-family:#{FONT};font-size:16px;line-height:20px;font-weight:700;color:#ffffff;text-decoration:none;">#{h(action[:label])}</a>
                </td>
              </tr>
            </table>
            <!--<![endif]-->
          </td>
        </tr>
      BUTTON
      if note
        rows << %(<tr><td style="padding:12px 28px 0 28px;font-family:#{FONT};font-size:14px;line-height:1.5;color:#{MUTED_TEXT};">#{h(note)}</td></tr>)
      end
      rows << <<~FALLBACK.strip
        <tr>
          <td style="padding:16px 28px 0 28px;font-family:#{FONT};font-size:12px;line-height:1.5;color:#{MUTED_TEXT};">
            Button not working? Copy this link into your browser:<br>
            <a href="#{url}" target="_blank" rel="noopener" style="color:#{MUTED_TEXT};text-decoration:underline;word-break:break-all;overflow-wrap:anywhere;">#{url}</a>
          </td>
        </tr>
      FALLBACK
      rows.join("\n")
    end

    # Outlook's VML button needs a fixed width; about 10px a character.
    def button_width
      (action[:label].to_s.length * 10) + 60
    end

    def footer_html
      lines = footer_lines.map { |line| h(line) }
      %(<p style="margin:16px 0 0 0;font-family:#{FONT};font-size:12px;line-height:1.6;color:#{MUTED_TEXT};">#{lines.first}</p>) +
        %(<p style="margin:8px 0 0 0;font-family:#{FONT};font-size:12px;line-height:1.6;color:#{MUTED_TEXT};">#{lines.last}</p>)
    end
  end
end
