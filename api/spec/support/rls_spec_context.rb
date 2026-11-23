# frozen_string_literal: true

# RSpec examples run serially within each worker. Legacy fixtures and unit
# specs use the test owner, including their test-driver threads. Application
# entry points and :rls examples always check protected queries.
module RlsSpecContext
  class << self
    attr_accessor :fixture_exemption

    def exempt?
      fixture_exemption && !ActiveSupport::IsolatedExecutionState[:rls_strict_example]
    end

    def strict
      state = ActiveSupport::IsolatedExecutionState
      previous = state[:rls_strict_example]
      state[:rls_strict_example] = true
      yield
    ensure
      state[:rls_strict_example] = previous
    end
  end

  self.fixture_exemption = true

  module Guard
    def check!(...)
      super unless RlsSpecContext.exempt?
    end
  end

  module Request
    def process(...)
      RlsSpecContext.strict { super }
    end
  end

  module Job
    def perform_now
      RlsSpecContext.strict { super }
    end
  end
end

RlsContextGuard.singleton_class.prepend(RlsSpecContext::Guard)
ActionDispatch::Integration::Session.prepend(RlsSpecContext::Request)
ApplicationJob.prepend(RlsSpecContext::Job)

RSpec.configure do |config|
  config.around do |example|
    previous = RlsSpecContext.fixture_exemption
    RlsSpecContext.fixture_exemption = !example.metadata[:rls]
    violations = []
    subscriber = lambda do |event|
      violations << event.payload if !example.metadata[:rls] && !RlsSpecContext.exempt?
    end
    ActiveSupport::Notifications.subscribed(subscriber, "rls.context_violation") { example.run }
    expect(violations).to be_empty, "Unscoped application queries: #{violations.uniq.inspect}"
  ensure
    RlsSpecContext.fixture_exemption = previous
  end
end
