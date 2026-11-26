# frozen_string_literal: true

namespace :employee_emails do
  desc "Write every employee email, with made-up data, to tmp/employee_email_previews (or DIR)"
  task preview: :environment do
    dir = ENV["DIR"].presence || Rails.root.join("tmp/employee_email_previews").to_s
    EmployeeEmails::Preview.write!(dir).each { |path| puts path }
  end
end
