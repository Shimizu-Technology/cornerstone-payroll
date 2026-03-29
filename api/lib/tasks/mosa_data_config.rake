# frozen_string_literal: true

# Comprehensive MoSa's Hotbox, Inc. data setup
# Creates ALL employees and configurations from scratch based on
# Cornerstone payroll preview data (PPE 2026.03.07, PD 2026.03.12)
namespace :mosa do
  desc "Full rebuild: company + all 51 employees + deductions + retirement"
  task rebuild: :environment do
    ActiveRecord::Base.transaction do
      puts "=" * 70
      puts "MoSa's Hotbox, Inc. — Full Data Rebuild"
      puts "=" * 70

      company = Company.find_or_create_by!(name: "MoSa's Hotbox, Inc.") do |c|
        c.city = "Dededo"
        c.state = "GU"
        c.pay_frequency = "biweekly"
      end
      company_id = company.id
      puts "Company: #{company.name} (ID: #{company_id})"

      # ==================================================================
      # ALL 51 EMPLOYEES
      # Rates derived from Cornerstone preview: regular_pay / regular_hours
      # ==================================================================
      puts "\n--- Creating employees ---"

      all_employees = [
        # Salaried owners (variable pay per period)
        { first_name: "Monique", last_name: "Amani", type: "salary", rate: 225062.76, filing: "single" },
        { first_name: "Sara", last_name: "Doctor", type: "salary", rate: 225062.76, filing: "single" },

        # Hourly employees (alphabetical by last name)
        { first_name: "Julie", middle_name: "R.", last_name: "Arthur", type: "hourly", rate: 11.00, filing: "single" },
        { first_name: "Vincent", last_name: "Belleza", type: "hourly", rate: 16.00, filing: "single" },
        { first_name: "Zachary", last_name: "Camacho", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Ava", last_name: "Cruz", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Chad", last_name: "Cruz", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Dennis", last_name: "Doctor", type: "hourly", rate: 19.00, filing: "single" },
        { first_name: "Fredly", last_name: "Fred", type: "hourly", rate: 12.25, filing: "single" },
        { first_name: "Roselaine", last_name: "Gumataotao", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Eithen", last_name: "Hadley", type: "hourly", rate: 12.50, filing: "single" },
        { first_name: "Esleen", middle_name: "Trina", last_name: "Haser", type: "hourly", rate: 10.50, filing: "single" },
        { first_name: "Cason", last_name: "Jackson", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Nena", last_name: "Joe", type: "hourly", rate: 19.00, filing: "single" },
        { first_name: "Verna", last_name: "John", type: "hourly", rate: 15.50, filing: "single" },
        { first_name: "Sonia", last_name: "Lesegbul", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Heather", last_name: "Likiaksa", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "Iuver", middle_name: "Jr.", last_name: "Likiaksa", type: "hourly", rate: 11.00, filing: "single" },
        { first_name: "Stephanie", last_name: "Likiaksa", type: "hourly", rate: 13.50, filing: "single" },
        { first_name: "Florensa", last_name: "Luke", type: "hourly", rate: 11.00, filing: "single" },
        { first_name: "Brandon", last_name: "Mariano", type: "hourly", rate: 10.00, filing: "single" },
        { first_name: "Jamar", last_name: "McWhorter", type: "hourly", rate: 10.25, filing: "single" },
        { first_name: "Judy", last_name: "Mochan", type: "hourly", rate: 12.00, filing: "head_of_household" },
        { first_name: "Addison", last_name: "Moyer", type: "hourly", rate: 35.00, filing: "married" },
        { first_name: "Shiloh", last_name: "Muna-Brecht", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Dorothy", last_name: "Nikonas", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Viany", last_name: "Olap", type: "hourly", rate: 17.00, filing: "single" },
        { first_name: "Jason", last_name: "Palsis", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Billy Ray", last_name: "Pedro", type: "hourly", rate: 12.50, filing: "single" },
        { first_name: "Charles", last_name: "Phillip", type: "hourly", rate: 17.50, filing: "single" },
        { first_name: "Douglas", last_name: "Phillip", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Emma", last_name: "Pleadwell", type: "hourly", rate: 17.00, filing: "single" },
        { first_name: "Jared", last_name: "Quichocho", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Sina", last_name: "Rhaym", type: "hourly", rate: 11.00, filing: "single" },
        { first_name: "Nicolette", last_name: "Roberto", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "Conception", last_name: "Rold", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "Aaron-Michael", last_name: "Root", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "J-one", last_name: "Serious", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "George", last_name: "Setik", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Madela", last_name: "Severin", type: "hourly", rate: 20.00, filing: "single" },
        { first_name: "Mayleen", last_name: "Severin", type: "hourly", rate: 14.00, filing: "single" },
        { first_name: "Ryan", last_name: "Shisler", type: "hourly", rate: 14.50, filing: "single" },
        { first_name: "Dorleen", last_name: "Songeni", type: "hourly", rate: 10.25, filing: "single" },
        { first_name: "Natalie", last_name: "Thomas", type: "hourly", rate: 10.25, filing: "single" },
        { first_name: "Atsy", last_name: "Toreph", type: "hourly", rate: 12.00, filing: "single" },
        { first_name: "Andrew", last_name: "Torres-Perez", type: "hourly", rate: 14.00, filing: "married" },
        { first_name: "Kaya", middle_name: "Mari", last_name: "Tubiera Dunn", type: "hourly", rate: 9.25, filing: "single" },
        { first_name: "Regina", last_name: "Umoumoch", type: "hourly", rate: 16.00, filing: "single" },
        { first_name: "Elain Diane", last_name: "Umwech", type: "hourly", rate: 15.50, filing: "single" },
        { first_name: "Johnny", middle_name: "Jr.", last_name: "Worswick", type: "hourly", rate: 11.00, filing: "single" },
      ]

      emp_map = {}
      all_employees.each do |attrs|
        emp = Employee.find_or_create_by!(
          company_id: company_id,
          first_name: attrs[:first_name],
          last_name: attrs[:last_name]
        ) do |e|
          e.middle_name = attrs[:middle_name]
          e.employment_type = attrs[:type]
          e.pay_rate = attrs[:rate]
          e.pay_frequency = "biweekly"
          e.filing_status = attrs[:filing]
          e.allowances = 0
          e.status = "active"
        end
        key = "#{attrs[:first_name]} #{attrs[:last_name]}"
        emp_map[key] = emp
        puts "  #{emp.employment_type.ljust(7)} #{emp.full_name.ljust(30)} $#{emp.pay_rate}"
      end

      puts "\nTotal employees: #{Employee.where(company_id: company_id).count}"

      # ==================================================================
      # ADDITIONAL WITHHOLDING (W-4 Step 4c)
      # For employees where Cornerstone withholds MORE FIT than our calc
      # ==================================================================
      puts "\n--- Setting additional withholding ---"

      additional_wh = {
        "Vincent Belleza" => 7.59,
        "Zachary Camacho" => 12.63,
        "Dennis Doctor" => 25.47,
        "Iuver Likiaksa" => 14.10,
        "Viany Olap" => 19.85,
        "Charles Phillip" => 30.23,
        "Douglas Phillip" => 39.69,
        "Emma Pleadwell" => 11.60,
        "Jared Quichocho" => 39.69,
        "Madela Severin" => 11.37,
        "Mayleen Severin" => 14.52,
        "Ryan Shisler" => 10.18,
      }

      additional_wh.each do |name, amount|
        emp = emp_map[name]
        unless emp
          puts "  WARN: #{name} not found"
          next
        end
        emp.update!(additional_withholding: amount)
        puts "  ADDTL_WH: #{emp.full_name.ljust(25)} +$#{amount}/period"
      end

      # ==================================================================
      # ROTH 401(k) RATES (employee and employer match)
      # ==================================================================
      puts "\n--- Configuring Roth 401(k) ---"

      roth_configs = {
        "Zachary Camacho"   => [0.04, 0.04],
        "Chad Cruz"         => [0.04, 0.04],
        "Dennis Doctor"     => [0.10, 0.04],
        "Nena Joe"          => [0.04, 0.04],
        "Verna John"        => [0.05, 0.04],
        "Heather Likiaksa"  => [0.10, 0.04],
        "Iuver Likiaksa"    => [0.03, 0.03],
        "Stephanie Likiaksa" => [0.03, 0.03],
        "Addison Moyer"     => [0.06, 0.04],
        "Charles Phillip"   => [0.05, 0.04],
        "Emma Pleadwell"    => [0.04, 0.04],
        "Madela Severin"    => [0.04, 0.04],
        "Mayleen Severin"   => [0.04, 0.04],
        "Ryan Shisler"      => [0.04, 0.04],
      }

      roth_configs.each do |name, (roth_rate, er_match)|
        emp = emp_map[name]
        unless emp
          puts "  WARN: #{name} not found"
          next
        end
        emp.update!(roth_retirement_rate: roth_rate, employer_roth_match_rate: er_match)
        puts "  ROTH: #{emp.full_name.ljust(25)} ee:#{(roth_rate * 100).round(1)}% er:#{(er_match * 100).round(1)}%"
      end

      # Owner employer match (pre-tax 401k match, handled via DeductionType)
      ["Monique Amani", "Sara Doctor"].each do |name|
        emp = emp_map[name]
        emp&.update!(employer_retirement_match_rate: 0.04)
        puts "  ER_MATCH: #{name.ljust(25)} 4% (pre-tax 401k)"
      end

      # ==================================================================
      # DEDUCTION TYPES
      # ==================================================================
      puts "\n--- Creating deduction types ---"

      deduction_defs = [
        { name: "Health Insurance",       category: "post_tax", sub_category: "insurance" },
        { name: "Loan",                   category: "post_tax", sub_category: "loan" },
        { name: "Auto Loan",             category: "post_tax", sub_category: "loan" },
        { name: "Rent",                   category: "post_tax", sub_category: "rent" },
        { name: "Phone",                  category: "post_tax", sub_category: "other" },
        { name: "Allotment",             category: "post_tax", sub_category: "allotment" },
        { name: "Case No. 2952492",      category: "post_tax", sub_category: "garnishment" },
        { name: "Remittance CS0018",     category: "post_tax", sub_category: "garnishment" },
        { name: "401(k) Pre-Tax",        category: "pre_tax",  sub_category: "retirement" },
        { name: "Loan (EH)",             category: "post_tax", sub_category: "loan" },
        { name: "Loan (Nena Joe)",       category: "post_tax", sub_category: "loan" },
        { name: "Loan (Douglas Phillip)", category: "post_tax", sub_category: "loan" },
      ]

      dt_map = {}
      deduction_defs.each do |attrs|
        dt = DeductionType.find_or_create_by!(company_id: company_id, name: attrs[:name]) do |d|
          d.category = attrs[:category]
          d.sub_category = attrs[:sub_category]
        end
        dt_map[attrs[:name]] = dt
        puts "  TYPE: #{dt.name} (#{dt.category})"
      end

      # ==================================================================
      # EMPLOYEE DEDUCTIONS
      # ==================================================================
      puts "\n--- Creating employee deductions ---"

      # Health insurance
      health_dt = dt_map["Health Insurance"]
      {
        "Fredly Fred" => 157.50, "Cason Jackson" => 157.50, "Verna John" => 157.50,
        "Heather Likiaksa" => 157.50, "Stephanie Likiaksa" => 157.50,
        "Billy Ray Pedro" => 157.50, "Johnny Worswick" => 157.50,
        "Addison Moyer" => 157.50,
        "Douglas Phillip" => 112.50, "Mayleen Severin" => 112.50,
      }.each do |name, amount|
        emp = emp_map[name]
        next unless emp
        EmployeeDeduction.find_or_create_by!(employee: emp, deduction_type: health_dt) do |d|
          d.amount = amount; d.is_percentage = false; d.active = true
        end
        puts "  #{emp.full_name.ljust(25)} Health Insurance $#{amount}"
      end

      # Loans (generic "Loan" type)
      loan_dt = dt_map["Loan"]
      loan_amounts = {
        "Julie Arthur" => 37.90, "Vincent Belleza" => 20.00, "Ava Cruz" => 64.20,
        "Dennis Doctor" => 50.50, "Fredly Fred" => 71.33, "Roselaine Gumataotao" => 7.50,
        "Eithen Hadley" => 12.00, "Esleen Haser" => 22.48, "Cason Jackson" => 63.50,
        "Verna John" => 228.00, "Sonia Lesegbul" => 28.00,
        "Heather Likiaksa" => 85.80, "Stephanie Likiaksa" => 69.40,
        "Iuver Likiaksa" => 32.50, "Brandon Mariano" => 17.48,
        "Jamar McWhorter" => 17.50, "Judy Mochan" => 20.00,
        "Shiloh Muna-Brecht" => 47.00, "Dorothy Nikonas" => 30.50,
        "Addison Moyer" => 66.68,
        "Viany Olap" => 110.00, "Jason Palsis" => 8.00, "Billy Ray Pedro" => 44.00,
        "Charles Phillip" => 108.25, "Douglas Phillip" => 194.84,
        "Emma Pleadwell" => 264.38, "Sina Rhaym" => 22.00,
        "Aaron-Michael Root" => 53.50, "George Setik" => 167.98,
        "Madela Severin" => 376.50, "Mayleen Severin" => 138.90,
        "Dorleen Songeni" => 47.50, "Atsy Toreph" => 38.40,
        "Kaya Tubiera Dunn" => 11.00, "Elain Diane Umwech" => 28.50,
        "Sara Doctor" => 40.00,
      }

      loan_amounts.each do |name, amount|
        emp = emp_map[name]
        unless emp
          puts "  WARN: #{name} not found for loan"
          next
        end
        EmployeeDeduction.find_or_create_by!(employee: emp, deduction_type: loan_dt) do |d|
          d.amount = amount; d.is_percentage = false; d.active = true
        end
        puts "  #{emp.full_name.ljust(25)} Loan $#{amount}"
      end

      # Named/special deductions
      named_deductions = [
        { emp: "Esleen Haser",    dt: "Loan (EH)",               amount: 50.00 },
        { emp: "Nena Joe",        dt: "Loan (Nena Joe)",         amount: 100.00 },
        { emp: "Charles Phillip", dt: "Auto Loan",               amount: 70.00 },
        { emp: "Charles Phillip", dt: "Rent",                    amount: 150.00 },
        { emp: "Charles Phillip", dt: "Phone",                   amount: 40.00 },
        { emp: "Douglas Phillip", dt: "Loan (Douglas Phillip)",  amount: 50.00 },
        { emp: "Douglas Phillip", dt: "Allotment",               amount: 482.08 },
        { emp: "Emma Pleadwell",  dt: "Auto Loan",               amount: 51.00 },
        { emp: "Verna John",      dt: "Case No. 2952492",        amount: 168.00 },
        { emp: "Jared Quichocho", dt: "Remittance CS0018",       amount: 184.62 },
      ]

      named_deductions.each do |config|
        emp = emp_map[config[:emp]]
        dt = dt_map[config[:dt]]
        unless emp && dt
          puts "  WARN: Missing #{config[:emp]} or #{config[:dt]}"
          next
        end
        EmployeeDeduction.find_or_create_by!(employee: emp, deduction_type: dt) do |d|
          d.amount = config[:amount]; d.is_percentage = false; d.active = true
        end
        puts "  #{emp.full_name.ljust(25)} #{config[:dt]} $#{config[:amount]}"
      end

      # Pre-tax 401(k) for owners (fixed dollar amounts, NOT percentage)
      pretax_401k = dt_map["401(k) Pre-Tax"]

      monique = emp_map["Monique Amani"]
      EmployeeDeduction.find_or_create_by!(employee: monique, deduction_type: pretax_401k) do |d|
        d.amount = 927.91; d.is_percentage = false; d.active = true
      end
      puts "  #{monique.full_name.ljust(25)} 401(k) Pre-Tax $927.91"

      sara = emp_map["Sara Doctor"]
      EmployeeDeduction.find_or_create_by!(employee: sara, deduction_type: pretax_401k) do |d|
        d.amount = 1216.35; d.is_percentage = false; d.active = true
      end
      puts "  #{sara.full_name.ljust(25)} 401(k) Pre-Tax $1,216.35"

      # ==================================================================
      # SUMMARY
      # ==================================================================
      puts "\n" + "=" * 70
      total = Employee.where(company_id: company_id).count
      dts = DeductionType.where(company_id: company_id).count
      eds = EmployeeDeduction.joins(:employee).where(employees: { company_id: company_id }).count
      puts "DONE: #{total} employees, #{dts} deduction types, #{eds} employee deductions"
      puts "=" * 70
    end
  end
end
