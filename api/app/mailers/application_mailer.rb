# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  self.delivery_job = ApplicationMailDeliveryJob

  before_deliver { Current.prevent_view_as_side_effects! }

  default from: "from@example.com"
  layout "mailer"
end
