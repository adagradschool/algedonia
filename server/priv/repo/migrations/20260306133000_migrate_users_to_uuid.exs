defmodule Algedonia.Repo.Migrations.MigrateUsersToUuid do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    alter table(:users) do
      add :uuid_id, :uuid
    end

    execute("UPDATE users SET uuid_id = gen_random_uuid() WHERE uuid_id IS NULL")
    execute("ALTER TABLE users ALTER COLUMN uuid_id SET NOT NULL")

    alter table(:workspace_memberships) do
      add :user_id_uuid, :uuid
    end

    execute("""
    UPDATE workspace_memberships AS wm
    SET user_id_uuid = u.uuid_id
    FROM users AS u
    WHERE wm.user_id = u.id
    """)

    execute("ALTER TABLE workspace_memberships ALTER COLUMN user_id_uuid SET NOT NULL")

    alter table(:workspace_invitations) do
      add :invited_by_id_uuid, :uuid
    end

    execute("""
    UPDATE workspace_invitations AS wi
    SET invited_by_id_uuid = u.uuid_id
    FROM users AS u
    WHERE wi.invited_by_id = u.id
    """)

    execute("ALTER TABLE workspace_invitations ALTER COLUMN invited_by_id_uuid SET NOT NULL")

    drop_if_exists constraint(:workspace_memberships, :workspace_memberships_user_id_fkey)
    drop_if_exists constraint(:workspace_invitations, :workspace_invitations_invited_by_id_fkey)

    drop_if_exists index(:workspace_memberships, [:workspace_id, :user_id])

    drop_if_exists index(:workspace_memberships, [:user_id],
                     name: :idx_workspace_memberships_user_id
                   )

    alter table(:workspace_memberships) do
      remove :user_id
    end

    rename table(:workspace_memberships), :user_id_uuid, to: :user_id

    alter table(:workspace_memberships) do
      modify :user_id, :uuid, null: false
    end

    create index(:workspace_memberships, [:user_id], name: :idx_workspace_memberships_user_id)
    create unique_index(:workspace_memberships, [:workspace_id, :user_id])

    alter table(:workspace_invitations) do
      remove :invited_by_id
    end

    rename table(:workspace_invitations), :invited_by_id_uuid, to: :invited_by_id

    alter table(:workspace_invitations) do
      modify :invited_by_id, :uuid, null: false
    end

    drop_if_exists constraint(:users, :users_pkey)

    alter table(:users) do
      remove :id
    end

    rename table(:users), :uuid_id, to: :id

    execute("ALTER TABLE users ADD PRIMARY KEY (id)")

    execute("""
    ALTER TABLE workspace_memberships
    ADD CONSTRAINT workspace_memberships_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES users(id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE workspace_invitations
    ADD CONSTRAINT workspace_invitations_invited_by_id_fkey
    FOREIGN KEY (invited_by_id)
    REFERENCES users(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    raise "Irreversible migration: original integer user IDs were replaced with UUIDs"
  end
end
