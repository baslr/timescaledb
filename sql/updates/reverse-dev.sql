-- Reverse of latest-dev.sql: remove per-column compression algorithm override.
--
-- NOTE: chunks that were actually compressed with a per-column algorithm
-- (e.g. flat_dictionary) cannot be read by versions without that algorithm.
-- Downgrading only removes the catalog column; it does not (and cannot)
-- rewrite already-compressed chunks.
ALTER TABLE _timescaledb_catalog.compression_settings
  DROP COLUMN IF EXISTS algorithm;
