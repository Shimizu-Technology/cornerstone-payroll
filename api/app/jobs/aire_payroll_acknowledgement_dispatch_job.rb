# frozen_string_literal: true

class AirePayrollAcknowledgementDispatchJob < ConnectedPayrollJob
  self.rls_mode = :system

  queue_as :default

  def perform
    AirePayrollAcknowledgement.dispatch_pending!
    AirePayrollEntryAcknowledgement.dispatch_pending!
    TimeTrackingCorrectionReceipt.dispatch_pending!
  end
end
