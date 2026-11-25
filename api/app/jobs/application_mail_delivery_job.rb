# frozen_string_literal: true

class ApplicationMailDeliveryJob < ActionMailer::MailDeliveryJob
  include ViewAsJobEnqueueGuard
end
