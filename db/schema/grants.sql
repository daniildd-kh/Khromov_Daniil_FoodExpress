DO $grant$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END;
$grant$;
GRANT ALL PRIVILEGES ON SCHEMA khromov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA khromov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA khromov_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA khromov_food TO inspector;
GRANT USAGE ON SCHEMA exts, information_schema, pg_catalog TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA khromov_food GRANT ALL PRIVILEGES ON TABLES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA khromov_food GRANT EXECUTE ON FUNCTIONS TO inspector;
