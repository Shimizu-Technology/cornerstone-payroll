# frozen_string_literal: true

require_relative "manual_fixture"

begin
  puts JSON.generate(StagingAcceptance::ManualFixture.new.run!)
rescue StagingAcceptance::ManualFixture::GuardError => e
  warn JSON.generate(fixture: StagingAcceptance::ManualFixture::FIXTURE, status: "blocked", reason: e.message)
  exit 1
rescue StandardError => e
  # Model/transport exceptions can contain personal identifiers. Preserve
  # their class only; private operator evidence can investigate separately.
  warn JSON.generate(fixture: StagingAcceptance::ManualFixture::FIXTURE, status: "blocked", error_class: e.class.name)
  exit 1
end
