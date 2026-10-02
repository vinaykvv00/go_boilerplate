-- 0001_init.sql
-- Initial schema migration
-- This migration creates the foundational tables for the boilerplate application.

-- Users table: stores application users
CREATE TABLE IF NOT EXISTS users (
    id         BIGSERIAL PRIMARY KEY,
    email      TEXT NOT NULL UNIQUE,
    first_name TEXT,
    last_name  TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index on email for fast lookups (unique index already created by UNIQUE constraint)
CREATE INDEX IF NOT EXISTS idx_users_created_at ON users (created_at);
