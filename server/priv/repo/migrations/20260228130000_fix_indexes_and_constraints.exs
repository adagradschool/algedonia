defmodule Algedonia.Repo.Migrations.FixIndexesAndConstraints do
  use Ecto.Migration

  def up do
    create index(:workspace_memberships, [:user_id], name: :idx_workspace_memberships_user_id)

    create constraint(:workspace_memberships, :valid_role, check: "role IN ('member')")

    drop index(:comments, [:parent_id])

    create index(:comments, [:parent_id],
             where: "parent_id IS NOT NULL",
             name: :idx_comments_parent_id
           )
  end

  def down do
    drop index(:comments, [:parent_id], name: :idx_comments_parent_id)

    create index(:comments, [:parent_id])

    drop constraint(:workspace_memberships, :valid_role)

    drop index(:workspace_memberships, [:user_id], name: :idx_workspace_memberships_user_id)
  end
end
