# frozen_string_literal: true

module EmployeeDocuments
  # How long a posted W-2GU copy stays in the app (M4-5). An electronically
  # furnished W-2 must stay available through October 15 of the year after
  # the tax year (26 CFR 31.6051-1(j)), so a former employee's read-only
  # access never ends before that while they have a posted copy. Paper still
  # goes out in the pilot; this keeps the app copy from vanishing early.
  module TaxFormRetention
    module_function

    # The end of October 15 of the following year, Guam time.
    def available_through(tax_year)
      Time.find_zone!(PayrollBusinessClock::TIME_ZONE).local(tax_year.to_i + 1, 10, 15).end_of_day
    end

    # The latest copy's retention end for this employee, or nil. A withdrawn
    # copy counts: its corrected form is still to come.
    def floor_for(employee)
      year = EmployeeDocument.tax_forms.where(company_id: employee.company_id, employee_id: employee.id, status: %w[posted withdrawn])
        .maximum(:tax_year)
      available_through(year) if year
    end

    # The retention floor extends tax forms and pay stubs beyond the profile cutoff.
    def access_until(employee, profile_until:)
      [ profile_until, floor_for(employee) ].compact.max
    end

    # Lengthens the employee's open former links whose access would end before
    # the copy's retention date. A link whose access already ended is left
    # closed. Only former_access_until moves (tax forms and pay stubs);
    # former_profile_access_until keeps the original cutoff, which is first
    # recorded here for a link made former before it existed. Called under
    # the posting's company lock.
    def extend_former_access!(employee:, tax_year:, actor: nil, user: nil)
      floor = available_through(tax_year)
      EmployeeAccountLink.where(company_id: employee.company_id, employee_id: employee.id, status: "former")
        .where("former_access_until > ? AND former_access_until < ?", Time.current, floor)
        .order(:id).lock.each do |link|
          previous = link.former_access_until
          link.update!(former_access_until: floor, former_profile_access_until: link.former_profile_access_until || previous)
          EmployeeLinks.audit!(link, "former_access_extended_for_tax_form", user: user, actor: actor,
            metadata: { tax_year: tax_year, previous_former_access_until: previous.iso8601, former_access_until: floor.iso8601 })
        end
    end
  end
end
