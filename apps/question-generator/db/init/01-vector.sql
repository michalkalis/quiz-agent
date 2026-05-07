-- Enable pgvector in the local quiz_pack database on first boot.
-- Mirrors what we'll run on Fly Postgres after `fly postgres create`
-- (see README "Cloud provisioning" section).
CREATE EXTENSION IF NOT EXISTS vector;
