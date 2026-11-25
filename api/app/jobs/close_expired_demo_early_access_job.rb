# frozen_string_literal: true

# Turns off demo employee app switches once the demo early-access rule stops
# applying (M4-9d), so an expired window closes without anyone acting.
class CloseExpiredDemoEarlyAccessJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default

  def perform
    EmployeeAppSwitch::DemoExpiry.call
  end
end
