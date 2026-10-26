CREATE SCHEMA IF NOT EXISTS posts;
CREATE TABLE IF NOT EXISTS posts.posts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caption    text NOT NULL CHECK (char_length(caption) BETWEEN 1 AND 2200),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS posts_created_at_idx ON posts.posts (created_at DESC);
