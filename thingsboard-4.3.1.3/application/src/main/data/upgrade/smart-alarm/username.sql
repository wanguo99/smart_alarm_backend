-- Smart Alarm extension: split the login username from the optional contact email.
ALTER TABLE tb_user ADD COLUMN IF NOT EXISTS username varchar(64);

UPDATE tb_user
SET username = lower(email)
WHERE username IS NULL;

ALTER TABLE tb_user ALTER COLUMN username SET NOT NULL;

DO
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tb_user_username_key') THEN
        ALTER TABLE tb_user ADD CONSTRAINT tb_user_username_key UNIQUE (username);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tb_user_username_format_chk') THEN
        ALTER TABLE tb_user ADD CONSTRAINT tb_user_username_format_chk CHECK (
            username ~ '^([a-z0-9][a-z0-9._@-]{1,62}[a-z0-9]|\+[0-9]{3,63})$'
        );
    END IF;
END;
$$;

-- Keep the standalone same-version migration compatible with the username-aware alarm queries.
CREATE OR REPLACE VIEW alarm_info AS
SELECT a.*,
(CASE WHEN a.acknowledged AND a.cleared THEN 'CLEARED_ACK'
      WHEN NOT a.acknowledged AND a.cleared THEN 'CLEARED_UNACK'
      WHEN a.acknowledged AND NOT a.cleared THEN 'ACTIVE_ACK'
      WHEN NOT a.acknowledged AND NOT a.cleared THEN 'ACTIVE_UNACK' END) as status,
COALESCE(CASE WHEN a.originator_type = 0 THEN (select title from tenant where id = a.originator_id)
              WHEN a.originator_type = 1 THEN (select title from customer where id = a.originator_id)
              WHEN a.originator_type = 2 THEN (select username from tb_user where id = a.originator_id)
              WHEN a.originator_type = 3 THEN (select title from dashboard where id = a.originator_id)
              WHEN a.originator_type = 4 THEN (select name from asset where id = a.originator_id)
              WHEN a.originator_type = 5 THEN (select name from device where id = a.originator_id)
              WHEN a.originator_type = 9 THEN (select name from entity_view where id = a.originator_id)
              WHEN a.originator_type = 13 THEN (select name from device_profile where id = a.originator_id)
              WHEN a.originator_type = 14 THEN (select name from asset_profile where id = a.originator_id)
              WHEN a.originator_type = 18 THEN (select name from edge where id = a.originator_id) END
    , 'Deleted') originator_name,
COALESCE(CASE WHEN a.originator_type = 0 THEN (select title from tenant where id = a.originator_id)
              WHEN a.originator_type = 1 THEN (select COALESCE(NULLIF(title, ''), email) from customer where id = a.originator_id)
              WHEN a.originator_type = 2 THEN (select username from tb_user where id = a.originator_id)
              WHEN a.originator_type = 3 THEN (select title from dashboard where id = a.originator_id)
              WHEN a.originator_type = 4 THEN (select COALESCE(NULLIF(label, ''), name) from asset where id = a.originator_id)
              WHEN a.originator_type = 5 THEN (select COALESCE(NULLIF(label, ''), name) from device where id = a.originator_id)
              WHEN a.originator_type = 9 THEN (select name from entity_view where id = a.originator_id)
              WHEN a.originator_type = 13 THEN (select name from device_profile where id = a.originator_id)
              WHEN a.originator_type = 14 THEN (select name from asset_profile where id = a.originator_id)
              WHEN a.originator_type = 18 THEN (select COALESCE(NULLIF(label, ''), name) from edge where id = a.originator_id) END
    , 'Deleted') as originator_label,
u.first_name as assignee_first_name, u.last_name as assignee_last_name,
u.email as assignee_email, u.username as assignee_username
FROM alarm a
LEFT JOIN tb_user u ON u.id = a.assignee_id;
