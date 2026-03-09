# frozen_string_literal: true

module PayrollImport
  # Parses Revel POS payroll PDF reports
  #
  # Example PDF structure (fixed-width columns):
  #      Employee                            Role               Ext. ID               Wage            Regular h.          Overtime h.        Doubletime h.                Regular            Overtime           Doubletime           Total Hours                  Total                 Fees
  #      Arthur, Juile R.                        -                     -                    -               58.99                      -                     -             604.64                       -                    -              58.99               604.64                      -
  #
  # Returns array of hashes with:
  # - employee_name (string): "Arthur, Juile R."
  # - regular_hours (decimal): 58.99
  # - overtime_hours (decimal): 0.0
  # - regular_pay (decimal): 604.64
  # - overtime_pay (decimal): 0.0
  # - total_hours (decimal): 58.99
  # - total_pay (decimal): 604.64
  class RevelPdfParser
    # Column positions determined by analyzing sample PDFs
    # Measured in character positions from start of line
    # Based on analysis of payroll_2025-12-15_00-00_to_2025-12-28_23-59.pdf
    COLUMNS = {
      employee: 0..39,          # "Arthur, Juile R." ends around position 39
      role: 40..59,             # "-" appears at position ~45
      ext_id: 60..79,           # "-" appears at position ~65
      wage: 80..99,             # "-" appears at position ~85
      regular_hours: 100..119,  # "58.99" appears at position ~104-109
      overtime_hours: 120..139, # "-" appears at position ~130
      doubletime_hours: 140..159, # "-" appears at position ~150
      regular_pay: 160..179,    # "604.64" appears at position ~164-170
      overtime_pay: 180..199,   # "-" appears at position ~190
      doubletime_pay: 200..219, # "-" appears at position ~210
      total_hours: 220..239,    # "58.99" appears at position ~228-233
      total_pay: 240..259,      # "604.64" appears at position ~248-254
      fees: 260..279            # "-" appears at position ~270
    }.freeze

    class << self
      # Parse PDF file and return array of employee records
      # @param file_path [String] path to PDF file
      # @return [Array<Hash>] parsed employee records
      def parse(file_path)
        new(file_path).parse
      end

      # Parse PDF from file upload (ActiveStorage blob or Tempfile)
      # @param file [File, Tempfile, ActionDispatch::Http::UploadedFile]
      # @return [Array<Hash>] parsed employee records
      def parse_file(file)
        return parse(file.path) if file.respond_to?(:path)

        tempfile = save_to_temp(file)
        begin
          parse(tempfile.path)
        ensure
          tempfile.unlink if tempfile
        end
      end

      private

      def save_to_temp(file)
        tempfile = Tempfile.new([ "upload", ".pdf" ])
        tempfile.binmode
        tempfile.write(file.read)
        tempfile.close
        tempfile
      end
    end

    def initialize(file_path)
      @file_path = file_path
      validate_file!
    end

    def parse
      text = extract_text
      lines = text.split("\n")

      header_index = find_header_line(lines)
      employee_lines = find_employee_lines(lines, header_index)
      parse_employee_lines(employee_lines)
    end

    private

    attr_reader :file_path

    def validate_file!
      raise ArgumentError, "File not found: #{file_path}" unless File.exist?(file_path)
      raise ArgumentError, "File is not a PDF" unless file_path.match?(/\.pdf\z/i)
    end

    def extract_text
      reader = PDF::Reader.new(file_path)
      reader.pages.map(&:text).join("\n")
    end

    # Find the line containing column headers
    def find_header_line(lines)
      lines.each_with_index do |line, idx|
        return idx if line.match?(/Employee.*Role.*Ext\. ID.*Wage.*Regular h\./i)
      end
      nil
    end

    # Find lines that look like employee data rows
    # Skip header, footer, and empty lines
    def find_employee_lines(lines, header_index)
      start_idx = header_index ? header_index + 1 : 0
      
      employee_lines = []
      i = start_idx
      
      while i < lines.length
        line = lines[i]
        
        # Skip empty lines
        if line.strip.empty?
          i += 1
          next
        end
        
        # Check if this looks like a total/footer line
        # Only break on a real totals line (has "Totals" AND multiple numbers)
        if line.match?(/^\s*Totals/i)
          # Check if it has payroll numbers (not just header)
          if line.match?(/\d+\.\d{2}/)
            break  # This is the real totals line, stop processing
          end
          # Otherwise continue (might be a header)
        end
        
        # Extract employee name portion
        name_part = line[COLUMNS[:employee]]&.strip || ""
        
        # Check if this line has payroll data
        has_numbers = line.match?(/\d+\.\d{2}/)
        
        # Case 1: Line has a name and numbers - could be complete or need next line's name
        if has_numbers && name_part.match?(/[A-Za-z]/)
          # Check if name ends with comma (like "Camacho,") - might need first name from next line
          if name_part.end_with?(',') && i + 1 < lines.length
            next_name = lines[i+1][COLUMNS[:employee]]&.strip || ""
            # If next line has text but no numbers, it's probably the first name
            if next_name.match?(/[A-Za-z]/) && !lines[i+1].match?(/\d+\.\d{2}/)
              # Merge: "Camacho," + "Zachary" = "Camacho, Zachary"
              combined_name = "#{name_part} #{next_name}".strip
              combined_line = combined_name.ljust(40) + line[40..].to_s
              employee_lines << combined_line
              i += 2  # Skip both lines
              next
            end
          end
          
          # Regular complete line
          employee_lines << line
          i += 1
          
        # Case 2: Line has name but no numbers - could be first part of multi-line name
        elsif name_part.match?(/[A-Za-z]/) && !has_numbers
          # Check if this is a name containing comma (e.g., "Camacho," or "Purcell, Cienna")
          # Could be start of multi-line name
          if (name_part.end_with?(',') || name_part.include?(',')) && i + 1 < lines.length
            next_line = lines[i+1]
            next_has_numbers = next_line.match?(/\d+\.\d{2}/)
            next_name = next_line[COLUMNS[:employee]]&.strip || ""
            
            if next_has_numbers && next_name.match?(/[A-Za-z]/)
              # Next line has first name and numbers - merge
              combined_name = "#{name_part} #{next_name}".strip
              combined_line = combined_name.ljust(40) + next_line[40..].to_s
              employee_lines << combined_line
              i += 2
              next
            end
          end
          
          # Couldn't determine - skip this line
          i += 1
          
        else
          # Doesn't look like employee data
          i += 1
        end
      end
      
      employee_lines
    end

    # Parse individual employee lines into structured data
    def parse_employee_lines(lines)
      lines.filter_map do |line|
        parse_employee_line(line)
      end
    end

    def normalize_name(name)
      return "" if name.nil?
      
      # Remove extra whitespace
      name = name.gsub(/\s+/, " ").strip
      
      # Fix trailing commas: "Likiaksa, Stephanie," -> "Likiaksa, Stephanie"
      name = name.sub(/,\s*$/, "") if name.end_with?(",")
      
      # Fix double commas: "Likiaksa, Stephanie, Iuver" -> "Likiaksa, Stephanie Iuver"
      # Actually this might be "Last, First Middle" which is fine
      
      # Revel payroll rows are in "Last, First" format.
      # If comma is missing due to extraction noise, do NOT invert tokens here;
      # leave as-is and let NameMatcher fuzzy logic resolve safely.
      
      name
    end

    def parse_employee_line(line)
      values = parse_fixed_columns(line)
      values = parse_flexible_columns(line) if implausible_fixed_parse?(values)

      values[:employee] = normalize_name(values[:employee]) if values[:employee]

      return nil if values[:employee].to_s.match?(/total/i)
      return nil if values[:regular_hours].nil? && values[:total_pay].nil?
      return nil if values[:employee].to_s.strip.empty?
      return nil if values[:employee].to_s.split(",").length < 2 && !values[:employee].to_s.include?(" ")

      hourly_rate = calculate_hourly_rate(values)

      {
        employee_name: values[:employee],
        regular_hours: values[:regular_hours] || 0.0,
        overtime_hours: values[:overtime_hours] || 0.0,
        regular_pay: values[:regular_pay] || 0.0,
        overtime_pay: values[:overtime_pay] || 0.0,
        total_hours: values[:total_hours] || 0.0,
        total_pay: values[:total_pay] || 0.0,
        hourly_rate: hourly_rate
      }
    end

    def parse_fixed_columns(line)
      values = {}
      COLUMNS.each do |field, range|
        raw = line[range]&.strip
        values[field] = convert_value(field, raw)
      end
      values
    end

    def implausible_fixed_parse?(values)
      # 200h ceiling matches MAX_REALISTIC_HOURS in validation script (14 days * ~14h max).
      # Catches compressed-layout lines like PP09 Thomas/Natalie where fixed columns
      # misread regular_pay (224.41) as total_hours; fallback flexible parser resolves correctly.
      values[:employee].to_s.strip.empty? || values[:total_hours].to_f > 200.0 || (values[:total_pay].to_f > 0 && values[:total_hours].to_f.zero?)
    end

    def parse_flexible_columns(line)
      tokens = line.scan(/-|\d[\d,]*\.\d{2}/)
      numeric = tokens.last(9)

      values = {
        employee: line[0..39]&.strip,
        regular_hours: convert_value(:regular_hours, numeric[0]),
        overtime_hours: convert_value(:overtime_hours, numeric[1]),
        doubletime_hours: convert_value(:doubletime_hours, numeric[2]),
        regular_pay: convert_value(:regular_pay, numeric[3]),
        overtime_pay: convert_value(:overtime_pay, numeric[4]),
        doubletime_pay: convert_value(:doubletime_pay, numeric[5]),
        total_hours: convert_value(:total_hours, numeric[6]),
        total_pay: convert_value(:total_pay, numeric[7]),
        fees: convert_value(:fees, numeric[8])
      }

      values
    end

    def convert_value(field, raw)
      return nil if raw.nil? || raw.empty? || raw == "-"

      case field
      when :employee
        raw
      when :regular_hours, :overtime_hours, :doubletime_hours,
           :regular_pay, :overtime_pay, :doubletime_pay,
           :total_hours, :total_pay
        clean = raw.gsub(",", "")
        begin
          Float(clean)
        rescue ArgumentError, TypeError
          nil
        end
      else
        raw
      end
    end

    def calculate_hourly_rate(values)
      return nil if values[:total_hours].to_f.zero? || values[:total_pay].to_f.zero?
      values[:total_pay].to_f / values[:total_hours].to_f
    end
  end
end
