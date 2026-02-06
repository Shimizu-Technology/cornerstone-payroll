# Email Setup Guide (Resend)

A guide for setting up transactional email with Resend in Rails applications.

---

## Table of Contents
1. [Why Resend](#1-why-resend)
2. [Resend Account Setup](#2-resend-account-setup)
3. [Domain Verification & DNS](#3-domain-verification--dns)
4. [Rails Integration](#4-rails-integration)
5. [Email Service Pattern](#5-email-service-pattern)
6. [Email Templates](#6-email-templates)
7. [Testing & Debugging](#7-testing--debugging)
8. [Common Issues](#8-common-issues)

---

## 1. Why Resend

Resend is a modern email API for developers, offering:
- Simple API (easier than SendGrid/Postmark)
- Great developer experience
- Generous free tier (3,000 emails/month)
- Built-in analytics
- React Email support for templates

### Alternatives
| Provider | Free Tier | Best For |
|----------|-----------|----------|
| **Resend** | 3,000/month | Modern apps, developer experience |
| SendGrid | 100/day | High volume, marketing emails |
| Postmark | 100/month | Transactional-only, deliverability |
| AWS SES | 62,000/month (EC2) | AWS ecosystem, cost at scale |
| Mailgun | 5,000/month (3 months) | Flexibility, EU hosting |

---

## 2. Resend Account Setup

### Steps:
1. Go to [resend.com](https://resend.com) and sign up
2. Create a new API key in **API Keys** section
3. Copy the key (starts with `re_`)
4. Add to your environment variables

### API Key Security:
- Use different keys for dev/staging/production
- Never commit keys to git
- Rotate keys periodically

---

## 3. Domain Verification & DNS

To send from your own domain (not `onboarding@resend.dev`), you must verify it.

### Steps:
1. Go to **Domains** in Resend dashboard
2. Click **Add Domain**
3. Enter your domain (e.g., `example.com`)
4. Add the DNS records Resend provides

### Required DNS Records:

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| TXT | `@` or domain | `v=spf1 include:amazonses.com ~all` | SPF - authorizes sending |
| TXT | `resend._domainkey` | `p=MIGfMA0GCS...` (long key) | DKIM - email signing |
| TXT | `_dmarc` | `v=DMARC1; p=none;` | DMARC - policy |
| MX | `send` | `feedback-smtp.us-east-1.amazonses.com` | Bounce handling |

### Example Netlify DNS Setup:

```
Type: TXT
Name: @
Value: v=spf1 include:amazonses.com ~all
TTL: 3600

Type: TXT  
Name: resend._domainkey
Value: p=MIGfMA0GCSqGSIb3DQEBA... (full key from Resend)
TTL: 3600

Type: TXT
Name: _dmarc
Value: v=DMARC1; p=none;
TTL: 3600

Type: MX
Name: send
Value: 10 feedback-smtp.us-east-1.amazonses.com
TTL: 3600
```

### Verification:
- DNS propagation takes 5-60 minutes
- Check status in Resend dashboard
- All records must show "Verified"

---

## 4. Rails Integration

### Install the Gem

```ruby
# Gemfile
gem "resend"
```

```bash
bundle install
```

### Create Initializer

```ruby
# config/initializers/resend.rb
Resend.api_key = ENV["RESEND_API_KEY"]
```

### Environment Variables

```bash
# .env (development)
RESEND_API_KEY=re_your_dev_api_key
MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=http://localhost:5173

# Production (Render/Heroku)
RESEND_API_KEY=re_your_prod_api_key
MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=https://example.com
```

### .env.example

```bash
# EMAIL (Resend)
# Get your API key from: https://resend.com/api-keys
RESEND_API_KEY=re_your_api_key
MAILER_FROM_EMAIL=noreply@example.com
```

---

## 5. Mailer Pattern (Recommended)

The recommended approach is using a Rails Mailer that calls `Resend::Emails.send` directly (not ActionMailer's `mail()` method). This gives you the familiar mailer structure while avoiding ActionMailer's lazy evaluation issues.

### Create the Mailer

```ruby
# app/mailers/user_mailer.rb
class UserMailer < ApplicationMailer
  def invitation_email(user:, invited_by:)
    @user = user
    @invited_by = invited_by
    @sign_up_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")

    from_email = ENV.fetch("MAILER_FROM_EMAIL", "noreply@example.com")
    
    # Call Resend directly (NOT ActionMailer's mail() method)
    Resend::Emails.send({
      from: from_email,
      to: @user.email,
      subject: "You've been invited to Your App Name",
      html: invitation_html
    })
  end

  private

  def invitation_html
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Welcome</title>
      </head>
      <body style="margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #f5f5f5;">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 600px; margin: 0 auto; padding: 40px 20px;">
          <tr>
            <td>
              <!-- Header -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #2d2a26; border-radius: 12px 12px 0 0; padding: 30px;">
                <tr>
                  <td align="center">
                    <h1 style="color: #ffffff; margin: 0; font-size: 24px; font-weight: 600;">APP NAME</h1>
                  </td>
                </tr>
              </table>

              <!-- Content -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #ffffff; padding: 40px 30px;">
                <tr>
                  <td>
                    <h2 style="color: #2d2a26; margin: 0 0 20px 0; font-size: 22px;">You're Invited! 🎉</h2>
                    
                    <p style="color: #555555; font-size: 16px; line-height: 1.6; margin: 0 0 20px 0;">
                      #{@invited_by&.email || "An administrator"} has invited you to join the team portal.
                    </p>

                    <p style="color: #555555; font-size: 16px; line-height: 1.6; margin: 0 0 30px 0;">
                      You've been granted <strong>#{@user.role}</strong> access. Click the button below to create your account.
                    </p>

                    <!-- CTA Button -->
                    <table role="presentation" cellspacing="0" cellpadding="0" style="margin: 0 auto 30px auto;">
                      <tr>
                        <td style="background-color: #8b7355; border-radius: 8px;">
                          <a href="#{@sign_up_url}" target="_blank" style="display: inline-block; padding: 16px 32px; color: #ffffff; text-decoration: none; font-size: 16px; font-weight: 600;">
                            Create Your Account
                          </a>
                        </td>
                      </tr>
                    </table>

                    <p style="color: #888888; font-size: 14px; line-height: 1.6; margin: 0 0 10px 0;">
                      Or copy and paste this link into your browser:
                    </p>
                    <p style="color: #8b7355; font-size: 14px; word-break: break-all; margin: 0 0 30px 0;">
                      #{@sign_up_url}
                    </p>

                    <hr style="border: none; border-top: 1px solid #e5e5e5; margin: 30px 0;">

                    <p style="color: #888888; font-size: 14px; line-height: 1.6; margin: 0;">
                      <strong>Important:</strong> Make sure to sign up using this email address (<strong>#{@user.email}</strong>) to gain access.
                    </p>
                  </td>
                </tr>
              </table>

              <!-- Footer -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #f5f5f5; border-radius: 0 0 12px 12px; padding: 20px 30px;">
                <tr>
                  <td align="center">
                    <p style="color: #888888; font-size: 12px; margin: 0;">
                      Company Name<br>
                      City, State
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
      </html>
    HTML
  end
end
```

### Using the Mailer

```ruby
# In a controller
def create
  @user = User.create!(user_params)
  
  # Send invitation email
  send_invitation_email(@user)
  
  render json: { user: @user }, status: :created
end

private

def send_invitation_email(user)
  return unless ENV["RESEND_API_KEY"].present?

  begin
    UserMailer.invitation_email(user: user, invited_by: current_user)
    Rails.logger.info "Invitation email sent to #{user.email}"
  rescue => e
    Rails.logger.error "Failed to send invitation email: #{e.message}"
  end
end
```

### Key Points:

1. **Call `Resend::Emails.send` directly** - Don't use ActionMailer's `mail()` method
2. **No `.deliver_now` needed** - The email sends immediately when the method is called
3. **Use instance variables** - `@user`, `@invited_by` are available in the HTML helper
4. **Heredoc for HTML** - Use `<<~HTML` for clean inline templates

---

## 5.1 Alternative: Service Class Pattern

If you prefer a service class pattern (no inheritance from ApplicationMailer), you can use this approach instead:

```ruby
# app/services/email_service.rb
class EmailService
  class << self
    def send_invitation_email(user:, invited_by:)
      return false unless resend_configured?

      sign_up_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      from_email = ENV.fetch("MAILER_FROM_EMAIL", "noreply@example.com")

      response = Resend::Emails.send({
        from: from_email,
        to: user.email,
        subject: "You've been invited",
        html: invitation_html(user: user, invited_by: invited_by, sign_up_url: sign_up_url)
      })

      Rails.logger.info "Resend response: #{response.inspect}"
      true
    rescue StandardError => e
      Rails.logger.error "Failed to send email: #{e.message}"
      false
    end

    private

    def resend_configured?
      if ENV["RESEND_API_KEY"].blank?
        Rails.logger.warn "RESEND_API_KEY not configured"
        return false
      end
      true
    end

    def invitation_html(user:, invited_by:, sign_up_url:)
      # HTML template here...
    end
  end
end
```

**When to use each pattern:**

| Pattern | Best For |
|---------|----------|
| **Mailer** | Familiar Rails conventions, multiple email types, instance variables |
| **Service Class** | Simpler structure, explicit control, easier testing |

Both work equally well with Resend. The key is calling `Resend::Emails.send` directly instead of ActionMailer's built-in delivery.

---

## 6. Email Templates

A full template is shown in Section 5 above. Here are additional best practices and examples.

### Email Template Best Practices:
- Use inline styles (no external CSS)
- Use tables for layout (email client compatibility)
- Max width 600px
- Include plain text fallback for important emails
- Test in multiple email clients (Gmail, Outlook, Apple Mail)

### Testing Templates:
- [Litmus](https://litmus.com/) - Paid, comprehensive
- [Email on Acid](https://www.emailonacid.com/) - Paid
- [Mailtrap](https://mailtrap.io/) - Free tier, good for dev

---

## 7. Testing & Debugging

### Local Development

Option 1: **Use Resend dev API key**
- Emails actually send (to your verified email only in dev)
- Good for testing delivery

Option 2: **Skip sending in development**
```ruby
def resend_configured?
  return false if Rails.env.development? && !ENV["FORCE_EMAILS"]
  
  if ENV["RESEND_API_KEY"].blank?
    Rails.logger.warn "RESEND_API_KEY not configured"
    return false
  end
  true
end
```

### Check Resend Dashboard

1. Go to [resend.com/emails](https://resend.com/emails)
2. Filter by "Sending" tab
3. Check status: Delivered, Bounced, etc.
4. Click on email to see details

### Debugging Checklist

```
□ RESEND_API_KEY is set in environment
□ Domain is verified in Resend
□ From email uses verified domain
□ To email is valid
□ Check Resend dashboard for delivery status
□ Check Rails logs for API response
□ Check spam folder
```

### Log the Response

```ruby
response = Resend::Emails.send({...})
Rails.logger.info "Resend response: #{response.inspect}"
# Response includes: { id: "email_id_here" }
```

---

## 8. Common Issues

### Issue: Emails not sending (no error)

**Cause**: Using ActionMailer's `mail()` method with Resend inside, which has lazy evaluation.

**Fix**: Call `Resend::Emails.send` directly in your mailer method (don't use ActionMailer's `mail()` method).

```ruby
# BAD - Using ActionMailer's mail() method
def invitation_email(user:)
  mail(to: user.email, subject: "Welcome") do |format|
    format.html { Resend::Emails.send(...) }  # Won't work reliably
  end
end

# GOOD - Call Resend directly (what we use)
def invitation_email(user:)
  @user = user
  Resend::Emails.send({
    from: ENV["MAILER_FROM_EMAIL"],
    to: @user.email,
    subject: "Welcome",
    html: invitation_html
  })
end
```

### Issue: "Domain not verified" error

**Cause**: DNS records not propagated or incorrect
**Fix**: 
1. Check all DNS records in Resend dashboard
2. Wait up to 1 hour for propagation
3. Verify record values match exactly

### Issue: Emails going to spam

**Causes & Fixes**:
1. Missing SPF/DKIM/DMARC → Add all DNS records
2. New domain → Build reputation slowly
3. Spam trigger words → Avoid "FREE", "ACT NOW", etc.
4. No unsubscribe link → Add for marketing emails

### Issue: "Invalid API key"

**Cause**: Wrong or expired API key
**Fix**: 
1. Check key starts with `re_`
2. Regenerate key in Resend dashboard
3. Update environment variable
4. Restart server

### Issue: From email rejected

**Cause**: From email domain doesn't match verified domain
**Fix**: Use email from your verified domain

```ruby
# If you verified example.com:
from: "noreply@example.com"      # ✓ Works
from: "team@example.com"         # ✓ Works
from: "hello@otherdomain.com"    # ✗ Rejected
```

---

## Quick Checklist

```
□ Resend account created
□ API key generated and saved
□ Domain added to Resend
□ DNS records added:
  □ SPF (TXT)
  □ DKIM (TXT)
  □ DMARC (TXT)
  □ MX for bounce handling
□ Domain verified in Resend
□ resend gem installed
□ Initializer created
□ Environment variables set
□ UserMailer class created (or EmailService)
□ Test email sent successfully
□ Check email landed in inbox (not spam)
```

---

## Environment Variables Summary

```bash
# Required
RESEND_API_KEY=re_xxxxxxxxxxxxx

# Recommended
MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=https://example.com

# Optional
ADMIN_EMAIL=admin@example.com  # For error notifications
```

---

## API Reference

### Send Email

```ruby
Resend::Emails.send({
  from: "sender@example.com",
  to: "recipient@example.com",        # String or Array
  subject: "Subject line",
  html: "<p>HTML content</p>",        # Or use text: for plain text
  cc: "cc@example.com",               # Optional
  bcc: "bcc@example.com",             # Optional
  reply_to: "reply@example.com",      # Optional
  headers: { "X-Custom": "value" },   # Optional
  attachments: [                       # Optional
    {
      filename: "file.pdf",
      content: Base64.encode64(file_content)
    }
  ]
})
```

### Response

```ruby
{
  "id" => "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794"
}
```

---

*Last updated: January 2026*
