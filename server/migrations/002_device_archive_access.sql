-- Explicit, administrator-approved recovery for duplicate registrations of one device.
CREATE TABLE device_archive_access (
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    source_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, source_device_id),
    CHECK (device_id <> source_device_id)
);
-- Runtime may use recovery grants, but only administrators may create them.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wevault_app') THEN
        REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON device_archive_access FROM wevault_app;
        GRANT SELECT ON device_archive_access TO wevault_app;
    END IF;
END $$;
