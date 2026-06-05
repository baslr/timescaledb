-- Add per-column compression algorithm override support
ALTER TABLE _timescaledb_catalog.compression_settings
  ADD COLUMN IF NOT EXISTS algorithm TEXT[];
