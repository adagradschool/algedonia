defmodule Algedonia.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    # --- Workspaces ---

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :prefix, :text, null: false
      add :next_ticket_number, :bigint, null: false, default: 1
      add :github_repo_url, :text
      add :tracker_config, :map, null: false, default: %{}
      add :playback_config, :map, null: false, default: %{}
      add :defaults, :map, null: false, default: %{}
      add :planning_mode, :text, null: false, default: "auto"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])

    execute(
      """
      ALTER TABLE workspaces
      ADD CONSTRAINT workspaces_planning_mode_check
      CHECK (planning_mode IN ('auto', 'always_approve', 'always_review'))
      """,
      "ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_planning_mode_check"
    )

    # --- Users ---

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :email, :text
      add :github_id, :bigint
      add :github_username, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:name])
    create unique_index(:users, [:github_id])

    # --- Workspace Memberships ---

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id])

    execute(
      """
      ALTER TABLE workspace_memberships
      ADD CONSTRAINT valid_role
      CHECK (role IN ('owner', 'member'))
      """,
      "ALTER TABLE workspace_memberships DROP CONSTRAINT IF EXISTS valid_role"
    )

    # --- Workspace Invitations ---

    create table(:workspace_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :github_username, :text, null: false
      add :status, :text, null: false, default: "pending"

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :invited_by_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_invitations, [:workspace_id])
    create index(:workspace_invitations, [:github_username])

    create unique_index(:workspace_invitations, [:workspace_id, :github_username],
             where: "status = 'pending'",
             name: :workspace_invitations_pending_unique
           )

    execute(
      "ALTER TABLE workspace_invitations ADD CONSTRAINT workspace_invitations_status_check CHECK (status IN ('pending', 'accepted', 'cancelled'))",
      "ALTER TABLE workspace_invitations DROP CONSTRAINT workspace_invitations_status_check"
    )

    # --- Transition Hooks ---

    create table(:transition_hooks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :from_status, :text, null: false
      add :to_status, :text, null: false
      add :instruction, :text, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transition_hooks, [:workspace_id, :from_status, :to_status])
    create index(:transition_hooks, [:workspace_id])

    # --- Tickets ---

    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :description, :text
      add :number, :bigint, null: false
      add :status, :text, null: false, default: "backlog"
      add :type, :text, null: false
      add :coding_agent, :text, null: false, default: "claude_code"
      add :priority, :integer, null: false, default: 3
      add :assignee, :text
      add :acceptance_criteria, :text
      add :rubric, :text
      add :max_attempts, :integer, default: 10
      add :overview, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tickets, [:status], name: :idx_tickets_status)
    create index(:tickets, [:priority], name: :idx_tickets_priority)
    create index(:tickets, [:assignee], name: :idx_tickets_assignee)
    create index(:tickets, [:workspace_id], name: :idx_tickets_workspace_id)

    create unique_index(:tickets, [:workspace_id, :number],
             name: :idx_tickets_workspace_id_number
           )

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_status CHECK (status IN ('backlog', 'planning', 'halted', 'in_progress', 'completed', 'archived'))",
      "ALTER TABLE tickets DROP CONSTRAINT valid_status"
    )

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_type CHECK (type IN ('feature', 'bug', 'chore', 'spike'))",
      "ALTER TABLE tickets DROP CONSTRAINT valid_type"
    )

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_priority CHECK (priority >= 1 AND priority <= 5)",
      "ALTER TABLE tickets DROP CONSTRAINT valid_priority"
    )

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_coding_agent CHECK (coding_agent IN ('codex', 'claude_code'))",
      "ALTER TABLE tickets DROP CONSTRAINT valid_coding_agent"
    )

    # --- Comments ---

    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false

      add :parent_id, references(:comments, type: :binary_id, on_delete: :nilify_all)
      add :author, :text, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comments, [:ticket_id], name: :idx_comments_ticket_id)

    create index(:comments, [:parent_id],
             where: "parent_id IS NOT NULL",
             name: :idx_comments_parent_id
           )

    # --- Daemon Registrations ---

    create table(:daemon_registrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :display_name, :text
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "offline"
      add :capacity, :integer, null: false, default: 3
      add :running_loops, :integer, null: false, default: 0
      add :available_agents, {:array, :text}, null: false, default: []
      add :bare_repos, {:array, :text}, null: false, default: []
      add :last_heartbeat_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:daemon_registrations, [:name])
    create index(:daemon_registrations, [:user_id], name: :idx_daemon_registrations_user_id)
    create index(:daemon_registrations, [:status], name: :idx_daemon_registrations_status)

    execute(
      "ALTER TABLE daemon_registrations ADD CONSTRAINT valid_status CHECK (status IN ('online', 'unhealthy', 'offline'))",
      "ALTER TABLE daemon_registrations DROP CONSTRAINT valid_status"
    )

    # --- Loops ---

    create table(:loops, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false

      add :assigned_daemon_id,
          references(:daemon_registrations, type: :binary_id, on_delete: :nilify_all)

      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "pending"
      add :role, :text, null: false, default: "task"
      add :manual_gate, :boolean, default: false
      add :current_attempt, :integer, default: 0
      add :max_attempts, :integer, default: 10
      add :rubric, :text
      add :branch_name, :text
      add :checker_config, :map
      add :land_mode, :text
      add :pr_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loops, [:status], name: :idx_loops_status)
    create index(:loops, [:assigned_daemon_id], name: :idx_loops_assigned_daemon_id)
    create index(:loops, [:ticket_id], name: :idx_loops_ticket_id)

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_status_check CHECK (status IN ('pending', 'running', 'passed', 'failed'))",
      "ALTER TABLE loops DROP CONSTRAINT loops_status_check"
    )

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook'))",
      "ALTER TABLE loops DROP CONSTRAINT loops_role_check"
    )

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_land_mode_check CHECK (land_mode IN ('auto_land', 'review_gate') OR land_mode IS NULL)",
      "ALTER TABLE loops DROP CONSTRAINT loops_land_mode_check"
    )

    # --- Loop Steps ---

    create table(:loop_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :loop_id, references(:loops, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :attempt, :integer, null: false
      add :status, :text, null: false
      add :session_id, :text
      add :exit_code, :integer
      add :verdict, :text
      add :feedback, :text
      add :feedback_path, :text
      add :error, :text
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create index(:loop_steps, [:loop_id], name: :idx_loop_steps_loop_id)

    create index(:loop_steps, [:loop_id, :attempt, :role],
             name: :idx_loop_steps_loop_id_attempt_role
           )

    execute(
      "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check CHECK (role IN ('maker', 'checker'))",
      "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_role_check"
    )

    execute(
      "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_status_check CHECK (status IN ('running', 'completed', 'failed', 'handoff_invalid', 'interrupted'))",
      "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_status_check"
    )

    # --- Inline Reviews ---

    create table(:inline_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :loop_id, references(:loops, type: :binary_id, on_delete: :delete_all), null: false
      add :author, :text, null: false
      add :file_path, :text, null: false
      add :line_number, :integer, null: false
      add :diff_hunk, :text, null: false
      add :body, :text, null: false
      add :status, :text, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:inline_reviews, [:loop_id], name: :idx_inline_reviews_loop_id)

    execute(
      "ALTER TABLE inline_reviews ADD CONSTRAINT inline_reviews_status_check CHECK (status IN ('pending', 'addressed', 'resolved'))",
      "ALTER TABLE inline_reviews DROP CONSTRAINT inline_reviews_status_check"
    )
  end
end
