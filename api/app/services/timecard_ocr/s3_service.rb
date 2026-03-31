# DEPRECATED: Use TimecardOcr::StorageService instead.
# This file is kept to avoid load errors during transition.
# All functionality has been moved to storage_service.rb which uses R2.
module TimecardOcr
  S3Service = StorageService
end
