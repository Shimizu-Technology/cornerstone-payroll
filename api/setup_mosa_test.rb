#!/usr/bin/env ruby

require File.expand_path('config/environment', __dir__)

puts "Setting up MoSa test environment..."

# 1. Get MoSa company
mosa = Company.find_by(name: "MoSa's Joint")
cornerstone = Company.find_by(name: "Cornerstone Tax Services")

unless mosa
  puts "MoSa company not found!"
  exit 1
end

# 2. Update current user to be for MoSa company
user = User.find_by(email: 'jerry.shimizutechnology@gmail.com')
if user
  old_company = user.company
  user.update!(company: mosa)
  puts "Updated user #{user.email} from #{old_company.name} to #{mosa.name}"
end

# 3. Create a draft pay period for MoSa (Dec 15-27, 2025)
pay_period = PayPeriod.find_or_create_by!(
  company: mosa,
  start_date: Date.new(2025, 12, 15),
  end_date: Date.new(2025, 12, 27),
  pay_date: Date.new(2025, 12, 30),
  period_description: "Biweekly payroll - MoSa's Joint",
  status: "draft"
)

puts "Created pay period #{pay_period.id}: #{pay_period.start_date} to #{pay_period.end_date} (status: #{pay_period.status})"

# 4. Count employees
puts "\nCompany stats:"
puts "  MoSa employees: #{mosa.employees.count}"
puts "  Cornerstone employees: #{cornerstone.employees.count}"
puts "  Draft pay periods for MoSa: #{mosa.pay_periods.where(status: 'draft').count}"

puts "\nReady for MoSa import test!"