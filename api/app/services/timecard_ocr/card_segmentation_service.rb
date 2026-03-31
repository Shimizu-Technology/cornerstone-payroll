module TimecardOcr
  class CardSegmentationService
    TARGET_CARD_RATIO = 0.43
    MULTI_CARD_RATIO_THRESHOLD = 0.75
    MAX_CARD_COUNT = 4
    HORIZONTAL_TRIM_RATIO = 0.02
    PDF_RENDER_DPI = 400
    PDF_RENDER_QUALITY = 95

    def self.segment(file_path)
      new(file_path).segment
    end

    def initialize(file_path)
      @file_path = file_path
    end

    def segment
      source_image_paths.flat_map do |path|
        segment_image(path)
      end
    ensure
      @rendered_page_paths&.each do |page|
        page&.close
        page&.unlink
      end
    end

    private

    def segment_image(path_or_file)
      path = path_or_file.respond_to?(:path) ? path_or_file.path : path_or_file
      image = MiniMagick::Image.open(path)
      count = estimated_card_count(image.width, image.height)
      return [copy_as_jpeg(image)] if count == 1

      split_into_columns(image, count)
    end

    def source_image_paths
      return [@file_path] unless pdf_source?

      @rendered_page_paths = render_pdf_pages
    end

    def pdf_source?
      File.extname(@file_path).casecmp(".pdf").zero? || File.binread(@file_path, 4) == "%PDF"
    rescue Errno::ENOENT, EOFError
      false
    end

    def render_pdf_pages
      pdf_page_count.times.map do |page_index|
        render_pdf_page(page_index)
      end
    end

    def pdf_page_count
      image = MiniMagick::Image.open(@file_path)
      [image["%n"].to_i, 1].max
    end

    def render_pdf_page(page_index)
      output = Tempfile.new(["timecard-pdf-page", ".jpg"])
      output.binmode
      output.close

      image_magick_binary = system("which magick > /dev/null 2>&1") ? "magick" : "convert"
      success = system(
        image_magick_binary,
        "-density", PDF_RENDER_DPI.to_s,
        "-units", "PixelsPerInch",
        "#{@file_path}[#{page_index}]",
        "-background", "white",
        "-alpha", "remove",
        "-alpha", "off",
        "-colorspace", "sRGB",
        "-quality", PDF_RENDER_QUALITY.to_s,
        output.path
      )
      raise "Failed to render PDF page #{page_index}" unless success

      output.open
      output.binmode
      output
    end

    def estimated_card_count(width, height)
      ratio = width.to_f / height.to_f
      return 1 if ratio < MULTI_CARD_RATIO_THRESHOLD

      [(ratio / TARGET_CARD_RATIO).round, 1].max.clamp(1, MAX_CARD_COUNT)
    end

    def split_into_columns(image, count)
      slice_width = image.width / count.to_f

      segments = count.times.filter_map do |index|
        left = (slice_width * index).round
        right = (slice_width * (index + 1)).round
        trim = (slice_width * HORIZONTAL_TRIM_RATIO).round

        crop_left = [left + trim, 0].max
        crop_width = [right - left - (trim * 2), 1].max

        segment = MiniMagick::Image.open(image.path)
        segment.crop("#{crop_width}x#{image.height}+#{crop_left}+0")
        tempfile = normalize_to_tempfile(segment)

        if segment_has_content?(tempfile)
          tempfile
        else
          Rails.logger.info("CardSegmentation: skipping blank segment #{index + 1}/#{count}")
          tempfile.close
          tempfile.unlink
          nil
        end
      end

      segments.empty? ? [copy_as_jpeg(image)] : segments
    end

    def segment_has_content?(tempfile)
      path = tempfile.respond_to?(:path) ? tempfile.path : tempfile
      image = MiniMagick::Image.open(path)
      std_dev = image["%[fx:standard_deviation]"].to_f
      std_dev > 0.08
    rescue => e
      Rails.logger.warn("CardSegmentation: content check failed (#{e.message}), keeping segment")
      true
    end

    def copy_as_jpeg(image)
      normalize_to_tempfile(MiniMagick::Image.open(image.path))
    end

    def normalize_to_tempfile(image)
      image.format("jpeg")
      output = Tempfile.new(["timecard-segment", ".jpg"])
      output.binmode
      image.write(output.path)
      output
    end
  end
end
