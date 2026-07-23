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
