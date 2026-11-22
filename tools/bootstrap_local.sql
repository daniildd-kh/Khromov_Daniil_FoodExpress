-- Только предусловия нового изолированного dev-кластера
-- Не входит в db/schema и не пересоздаёт существующую exts
CREATE SCHEMA IF NOT EXISTS exts;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA exts;
