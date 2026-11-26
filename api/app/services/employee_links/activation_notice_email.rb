# frozen_string_literal: true

module EmployeeLinks
  # Durable security notice sent to the employee's email address ON FILE
  # (persisted on the link inside the activation transaction before activation
  # changes any contact details) whenever their employee app link becomes
  # active. Carries only the employer's name and branding, the activation date
  # in Guam time and a link to the app — never pay data or sign-in credentials.
  #
  # schedule! writes the pre-change address and pending status in the same
  # transaction as link activation and enqueues SendEmployeeActivationNoticeJob
  # after commit. Retries reuse the same idempotency key and re-check
  # DemoOutbound every attempt.
  module ActivationNoticeEmail
    class DeliveryError < StandardError; end

    CHANNEL = "employee_link_activation_notice"
    MAX_ATTEMPTS = 5
    RETRY_AFTER = 10.minutes

    module_function

    # Persists the pre-change address inside the caller's activation transaction
    # and schedules after-commit background dispatch.
    def schedule!(link:, email_on_file:)
      to = EmployeeLinks.normalized_email(email_on_file)
      return false unless EmployeeLinks.email_format?(to)

      link.update!(
        activation_notice_email: to,
        activation_notice_status: "pending",
        activation_notice_attempts: 0,
        activation_notice_sent_at: nil
      )
      link_id = link.id
      ActiveRecord.after_all_transactions_commit do
        enqueue_delivery(link_id)
      end
      true
    end

    # Enqueues background delivery after the activation transaction commits.
    # Solid Queue / DB enqueue errors must never fail an already-committed
    # activation request; leave the notice pending for the recurring sweep.
    def enqueue_delivery(link_id)
      SendEmployeeActivationNoticeJob.perform_later(link_id)
    rescue StandardError => error
      Rails.logger.warn(
        "[EmployeeLinks::ActivationNoticeEmail] Failed to enqueue activation notice for link #{link_id} " \
        "(#{error.class}); leaving pending for recurring retry sweep"
      )
    end

    # Dispatches a persisted pending/failed activation notice.
    # Raises DeliveryError on transport failure (after committing the failed
    # state and attempt count) so ActiveJob retries with the same idempotency
    # key and DemoOutbound checks.
    def deliver_pending!(link_id)
      link = EmployeeAccountLink.find_by(id: link_id)
      return :skipped unless link

      outcome = :skipped
      failure = nil

      link.with_lock do
        to = EmployeeLinks.normalized_email(link.activation_notice_email)
        next unless EmployeeLinks.email_format?(to)
        next if %w[sent skipped].include?(link.activation_notice_status)

        if link.activation_notice_status == "failed" && link.activation_notice_attempts >= MAX_ATTEMPTS
          outcome = :failed
          next
        end

        unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured? &&
            DemoOutbound.permit?(company: link.company, email: to, channel: CHANNEL)
          link.update!(activation_notice_status: "skipped")
          outcome = :skipped
          next
        end

        attempts = link.activation_notice_attempts + 1
        timestamp = link.activated_at || link.updated_at || Time.current
        begin
          response = DemoOutbound.scoped(link.company, channel: CHANNEL) do
            PortalNotifications::Transport.deliver(
              payload(link, to, timestamp),
              idempotency_key: idempotency_key(link, timestamp)
            )
          end
          if response["suppressed"]
            link.update!(activation_notice_status: "skipped", activation_notice_attempts: attempts)
            outcome = :skipped
          else
            link.update!(
              activation_notice_status: "sent",
              activation_notice_attempts: attempts,
              activation_notice_sent_at: Time.current
            )
            outcome = response["captured"] || response["staging_captured"] ? :captured : :sent
          end
        rescue StandardError => error
          Rails.logger.warn("[EmployeeLinks::ActivationNoticeEmail] Activation notice for link #{link.id} failed: #{error.class}")
          link.update!(activation_notice_status: "failed", activation_notice_attempts: attempts)
          failure = error
          outcome = :failed
        end
      end

      raise DeliveryError, "Activation notice delivery failed for link #{link.id}: #{failure.class}" if failure

      outcome
    end

    # Recovery sweep for any persisted pending/failed notices whose immediate
    # job was lost or needs retry.
    def retry_unsent!(limit: 100)
      due = EmployeeAccountLink.where(activation_notice_status: "pending")
        .or(
          EmployeeAccountLink.where(activation_notice_status: "failed")
            .where(activation_notice_attempts: ...MAX_ATTEMPTS)
            .where(updated_at: ..RETRY_AFTER.ago)
        )
        .order(:id)
        .limit(limit)

      processed = 0
      due.pluck(:id).each do |id|
        deliver_pending!(id)
        processed += 1
      rescue DeliveryError
        next
      end
      processed
    end

    def idempotency_key(link, activated_at = nil)
      timestamp = activated_at || link.activated_at || link.created_at || Time.current
      "employee-link-activated-#{link.id}-#{timestamp.to_i}"
    end

    def payload(link, to, activated_at)
      brand = EmployeeEmails::Brand.for(link.company)
      message(brand, activated_at: activated_at, app_url: AppUrl.origin_for(link.company)).payload(to: to)
    end

    def message(brand, activated_at:, app_url:)
      date_guam = EmployeeEmails::Message.guam_date(activated_at)
      EmployeeEmails::Message.new(
        brand: brand,
        subject: "Your #{brand.name} employee app account was set up",
        heading: "Your employee app account is set up",
        paragraphs: [
          "Your #{brand.name} employee app account was set up on #{date_guam} (Guam time).",
          "If this wasn't you, contact #{brand.name} or Cornerstone right away."
        ],
        action: (app_url && { label: "Open the employee app", url: app_url }),
        preheader: "Your account was set up on #{date_guam}."
      )
    end
  end
end
