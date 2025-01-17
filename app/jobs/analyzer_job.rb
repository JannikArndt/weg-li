class AnalyzerJob < ApplicationJob
  retry_on EXIFR::MalformedJPEG, attempts: 5, wait: :exponentially_longer
  retry_on ActiveStorage::FileNotFoundError, attempts: 5, wait: :exponentially_longer
  discard_on Encoding::UndefinedConversionError
  discard_on ActiveRecord::RecordInvalid

  # TODO: move me to notice
  def self.time_from_filename(filename)
    token = filename[/.*(20\d{6}_\d{6})/, 1]
    token ||= filename[/.*(20\d{2}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})/, 1]

    return nil unless token
    Time.zone.parse(token.gsub('-', '')) rescue nil
  end

  def perform(notice)
    fail NotYetAnalyzedError unless photos_analyzed?(notice)
    unless photos_processed?(notice)
      notice.photos.each { |image| ThumbnailerJob.perform_later(image) }

      fail NotYetProcessedError
    end

    analyze(notice)
  end

  def analyze(notice)
    handle_exif(notice)

    begin
      handle_ml(notice)
    rescue HTTP::TimeoutError, HTTP::ResponseError => exception
      Appsignal.set_error(exception)
      handle_vision(notice)
    end

    notice.status = :open
    notice.save_incomplete!
  end

  private

  def handle_ml(notice)
    notice.photos.each do |photo|
      result = annotator.annotate_yolo(photo.key)

      if result.present?
        data_set = notice.data_sets.create!(data: result, kind: :car_ml, keyable: photo)
        # skip if we got lucky
        registrations = data_set.registrations
        if registrations.present?
          apply_registrations(notice, registrations, data_set)

          return
        end
      end
    end
  end

  def handle_vision(notice)
    prefixes = notice.user.district&.prefixes || []

    notice.photos.each do |photo|
      result = annotator.annotate_object(photo.key)

      if result.present?
        data_set = notice.data_sets.create!(data: result, kind: :google_vision, keyable: photo)
        # skip if we got lucky
        registrations = data_set.registrations
        if registrations.present?
          apply_registrations(notice, registrations, data_set)

          return
        end
      end
    end
  end

  def apply_registrations(notice, registrations, data_set)
    if notice.user.from_history?
      notice.apply_favorites(registrations)
    end

    if notice.user.from_recognition?
      notice.registration ||= registrations.first
      notice.brand ||= data_set.brands.first
      notice.color ||= data_set.colors.first
    end
  end

  def annotator
    @annotator ||= Annotator.new
  end

  def handle_exif(notice)
    notice.photos.each do |photo|
      exif = photo.service.download_file(photo.key) { |file| exifer.metadata(file) }
      if exif.present?
        exif_data_set = notice.data_sets.create!(data: exif, kind: :exif, keyable: photo)

        # the last or first exif is the good as any other
        coords = exif_data_set.coords

        if coords.present? && notice.data_sets.geocoder.blank?
          result = Geocoder.search(coords)
          if result.present?
            geocoder_data_set = notice.data_sets.create!(data: result, kind: :geocoder, keyable: photo)
            if notice.user.from_exif?
              address = geocoder_data_set.address
              notice.latitude = address[:latitude]
              notice.longitude = address[:longitude]
              notice.zip = address[:zip]
              notice.city = address[:city]
              notice.street = address[:street]
            end
          end
        end

        if coords.present? && notice.data_sets.proximity.blank?
          result = Notice.nearest_charges(*coords)
          if result.present?
            proximity_data_set = notice.data_sets.create!(data: result, kind: :proximity, keyable: photo)
            if notice.user.from_proximity?
              notice.charge ||= proximity_data_set.charges.first
            end
          end
        end
      end
    end

    if notice.user.from_exif?
      dates = notice.dates_from_photos
      notice.date ||= dates.first

      duration = notice.duration_from_photos
      notice.duration ||= duration
    end
  end

  def exifer
    @exifer ||= EXIFAnalyzer.new
  end
end
