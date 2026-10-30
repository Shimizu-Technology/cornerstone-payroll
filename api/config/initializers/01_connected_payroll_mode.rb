# frozen_string_literal: true

require Rails.root.join("lib/connected_payroll_mode")
ConnectedPayrollMode.validate!
Rails.logger.warn("CONNECTED_PAYROLL_MODE=#{ConnectedPayrollMode.mode}: #{ConnectedPayrollMode.enabled? ? 'connected payroll active' : 'Connected payroll is paused; delivery and locking held'}")
