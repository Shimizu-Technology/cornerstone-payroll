# frozen_string_literal: true

# Mail runs interceptors before Action Mailer serializes the delivery event.
# Run our boundary last so per-mailer settings and other interceptors cannot
# restore an unsafe adapter, including on Mail's forced delivery path.
module StagingMailBoundary
  def inform_interceptors
    super
    StagingMailInterceptor.delivering_email(self)
  end
end

Mail::Message.prepend(StagingMailBoundary)
