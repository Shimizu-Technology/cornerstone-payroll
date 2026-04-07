# frozen_string_literal: true

module PayrollImport
  # Matches employee names from PDF/Excel to database Employee records.
  #
  # PDF format: "Last, First M." (e.g., "Arthur, Juile R.")
  # Excel format: separate last_name / first_name columns
  #
  # Matching strategy (scored independently on last name + first name):
  # 1. Exact last name match (or prefix match for multi-word last names)
  # 2. First name: exact → first-token → nickname → fuzzy (Levenshtein ≤ 2)
  # 3. Combined confidence from last + first name match quality
  class NameMatcher
    CONFIDENCE_THRESHOLD = 0.6

    NAME_SUFFIXES = %w[jr sr ii iii iv v].freeze

    # Common English diminutives / nicknames (bidirectional).
    # Each key maps to one or more canonical forms that should also match.
    NICKNAMES = {
      "doug"    => %w[douglas],
      "douglas" => %w[doug],
      "mike"    => %w[michael],
      "michael" => %w[mike],
      "bill"    => %w[william],
      "william" => %w[bill will billy],
      "will"    => %w[william],
      "billy"   => %w[william],
      "bob"     => %w[robert],
      "robert"  => %w[bob rob bobby],
      "rob"     => %w[robert],
      "bobby"   => %w[robert],
      "jim"     => %w[james],
      "james"   => %w[jim jimmy],
      "jimmy"   => %w[james],
      "joe"     => %w[joseph],
      "joseph"  => %w[joe],
      "dan"     => %w[daniel],
      "daniel"  => %w[dan danny],
      "danny"   => %w[daniel],
      "dave"    => %w[david],
      "david"   => %w[dave],
      "tom"     => %w[thomas],
      "thomas"  => %w[tom tommy],
      "tommy"   => %w[thomas],
      "ed"      => %w[edward],
      "edward"  => %w[ed eddie],
      "eddie"   => %w[edward],
      "dick"    => %w[richard],
      "richard" => %w[dick rick],
      "rick"    => %w[richard],
      "steve"   => %w[steven stephen],
      "steven"  => %w[steve],
      "stephen" => %w[steve],
      "chris"   => %w[christopher],
      "christopher" => %w[chris],
      "matt"    => %w[matthew],
      "matthew" => %w[matt],
      "pat"     => %w[patrick patricia],
      "patrick" => %w[pat],
      "patricia" => %w[pat patty],
      "patty"   => %w[patricia],
      "tony"    => %w[anthony antonio],
      "anthony" => %w[tony],
      "sam"     => %w[samuel samantha],
      "samuel"  => %w[sam],
      "samantha" => %w[sam],
      "charlie" => %w[charles],
      "charles" => %w[charlie chuck],
      "chuck"   => %w[charles],
      "larry"   => %w[lawrence],
      "lawrence" => %w[larry],
      "jerry"   => %w[gerald jerome],
      "gerald"  => %w[jerry],
      "alex"    => %w[alexander alexandra],
      "alexander" => %w[alex],
      "alexandra" => %w[alex],
      "beth"    => %w[elizabeth],
      "elizabeth" => %w[beth liz],
      "liz"     => %w[elizabeth],
      "kate"    => %w[katherine catherine],
      "katherine" => %w[kate kathy],
      "catherine" => %w[kate cathy],
      "kathy"   => %w[katherine],
      "cathy"   => %w[catherine],
      "jen"     => %w[jennifer],
      "jennifer" => %w[jen jenny],
      "jenny"   => %w[jennifer],
      "sue"     => %w[susan suzanne],
      "susan"   => %w[sue],
      "suzanne" => %w[sue],
      "barb"    => %w[barbara],
      "barbara" => %w[barb],
      "nick"    => %w[nicholas],
      "nicholas" => %w[nick],
      "nate"    => %w[nathan nathaniel],
      "nathan"  => %w[nate],
      "nathaniel" => %w[nate],
      "ben"     => %w[benjamin],
      "benjamin" => %w[ben],
      "fred"    => %w[frederick],
      "frederick" => %w[fred],
      "ray"     => %w[raymond],
      "raymond" => %w[ray],
      "ron"     => %w[ronald],
      "ronald"  => %w[ron],
      "don"     => %w[donald],
      "donald"  => %w[don],
      "al"      => %w[albert alan alfred],
      "albert"  => %w[al],
      "alan"    => %w[al],
      "phil"    => %w[philip phillip],
      "philip"  => %w[phil],
      "phillip" => %w[phil],
      "ted"     => %w[theodore edward],
      "theodore" => %w[ted],
      "wally"   => %w[walter],
      "walter"  => %w[wally],
      "lenny"   => %w[leonard],
      "leonard" => %w[lenny],
      "antonio" => %w[tony],
    }.freeze

    attr_reader :employees

    def initialize(employees)
      @employees = employees
      @employee_index = build_employee_index
    end

    # Match a "Last, First M." formatted name from the PDF
    def match_pdf_name(full_name)
      parsed = parse_pdf_name(full_name)
      return nil unless parsed

      find_best_match(parsed[:last_name], parsed[:first_name])
    end

    # Match separate last/first name from Excel
    def match_excel_name(last_name, first_name)
      find_best_match(normalize(last_name), normalize(first_name))
    end

    private

    def parse_pdf_name(full_name)
      return nil if full_name.blank?

      parts = full_name.split(",", 2)
      return nil if parts.length < 2

      last_name = normalize(parts[0])
      first_name = normalize(parts[1])
      return nil if last_name.blank?

      { last_name: last_name, first_name: first_name }
    end

    # Score each employee and return the best match above threshold
    def find_best_match(input_last, input_first)
      return nil if input_last.blank?

      best = nil
      best_score = 0.0

      employees.each do |emp|
        last_score = score_last_name(input_last, normalize(emp.last_name))
        next if last_score < 0.8

        first_score = score_first_name(input_first, normalize(emp.first_name))
        next if first_score < 0.5

        # Weight: last name 40%, first name 60% (first name differentiates more)
        combined = (last_score * 0.4 + first_score * 0.6).round(2)

        if combined > best_score
          best_score = combined
          best = emp
        end
      end

      return nil unless best && best_score >= CONFIDENCE_THRESHOLD

      {
        employee_id: best.id,
        confidence: best_score,
        matched_name: best.full_name
      }
    end

    # Score last name match (0.0 - 1.0)
    def score_last_name(input, employee)
      return 1.0 if input == employee

      # Strip generational suffixes (Jr., Sr., II, etc.) that may appear in
      # either the source data or the DB but not both
      input_base = strip_name_suffix(input)
      emp_base = strip_name_suffix(employee)
      return 1.0 if input_base == emp_base

      # Prefix match for multi-word last names ("tubiera" matches "tubiera dunn")
      emp_words = emp_base.split(/\s+/)
      if emp_words.length > 1 && emp_words.first == input_base
        return 0.95
      end

      # Fuzzy match on base last names
      dist = ld(input_base, emp_base)
      max_len = [input_base.length, emp_base.length].max
      return 0.0 if max_len.zero?

      score = 1.0 - (dist.to_f / max_len)
      score >= 0.8 ? score : 0.0
    end

    # Score first name match (0.0 - 1.0)
    def score_first_name(input, employee)
      return 0.0 if input.blank?

      input_tokens = input.split(/\s+/)
      emp_tokens = employee.split(/\s+/)
      input_first = input_tokens.first
      emp_first = emp_tokens.first

      # Exact full match
      return 1.0 if input == employee

      # Exact first-token match (handles "Aaron" = "Aaron-Michael" via "aaron" = "aaron michael".first)
      return 1.0 if input_first == emp_first

      # First token of input matches first token of employee
      return 1.0 if input_first.present? && emp_first.present? && input_first == emp_first

      # Nickname match on first tokens
      if nickname_match?(input_first, emp_first)
        return 0.95
      end

      # Fuzzy match on first tokens (handles typos like "Elaine" vs "Elain")
      if input_first.present? && emp_first.present?
        dist = dld(input_first, emp_first)
        max_len = [input_first.length, emp_first.length].max
        if max_len > 0
          token_score = 1.0 - (dist.to_f / max_len)
          return token_score if token_score >= 0.7
        end
      end

      # Fuzzy match on full first name string
      dist = ld(input, employee)
      max_len = [input.length, employee.length].max
      return 0.0 if max_len.zero?

      full_score = 1.0 - (dist.to_f / max_len)
      full_score >= 0.6 ? full_score : 0.0
    end

    def nickname_match?(name_a, name_b)
      return false if name_a.blank? || name_b.blank?

      aliases_a = NICKNAMES[name_a] || []
      aliases_b = NICKNAMES[name_b] || []

      aliases_a.include?(name_b) || aliases_b.include?(name_a)
    end

    def build_employee_index
      employees.index_by(&:id)
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squeeze(" ").strip
    end

    def strip_name_suffix(name)
      tokens = name.split(/\s+/)
      tokens.reject { |t| NAME_SUFFIXES.include?(t) }.join(" ")
    end

    # Levenshtein distance
    def ld(s, t)
      return Levenshtein.distance(s, t) if defined?(Levenshtein)

      m = s.length
      n = t.length
      d = Array.new(m + 1) { |i| i }
      (1..n).each do |j|
        prev = d[0]
        d[0] = j
        (1..m).each do |i|
          cost = s[i - 1] == t[j - 1] ? 0 : 1
          temp = d[i]
          d[i] = [d[i] + 1, d[i - 1] + 1, prev + cost].min
          prev = temp
        end
      end
      d[m]
    end

    # Damerau-Levenshtein distance (transpositions count as 1 edit)
    def dld(s, t)
      m = s.length
      n = t.length
      d = Array.new(m + 1) { Array.new(n + 1, 0) }
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }

      (1..m).each do |i|
        (1..n).each do |j|
          cost = s[i - 1] == t[j - 1] ? 0 : 1
          d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
          if i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1]
            d[i][j] = [d[i][j], d[i - 2][j - 2] + 1].min
          end
        end
      end
      d[m][n]
    end
  end
end
