set dotenv-load

# Algedonia monorepo recipes
# Run `just --list` to see all available recipes

# Build the daemon CLI as "ag" and install to PATH
build-cli:
    cd daemon && go build -o ag ./cmd/algedonia-agent
    mkdir -p ~/bin
    mv daemon/ag ~/bin/ag

# Start the Phoenix dev server on port 4000
server:
    cd server && mix phx.server

# Run all formatters
format: format-server format-daemon

# Run all linters
lint: lint-server lint-daemon

# Run all tests
test: test-server test-daemon

# Format Elixir server code
format-server:
    cd server && mix format

# Format Go daemon code
format-daemon:
    cd daemon && go fmt ./...

# Lint Elixir server code
lint-server:
    cd server && mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict

# Lint Go daemon code
lint-daemon:
    cd daemon && go vet ./... && go build ./...

# Test Elixir server
test-server:
    cd server && mix test

# Test Go daemon
test-daemon:
    cd daemon && go test ./...

# Open the GitHub repo in the browser
github:
    open https://github.com/adagradschool/algedonia

# Deploy Phoenix server to Fly.io
deploy:
    cd server && fly deploy

# Nuke everything: DB, local daemon state/config, project runtime artifacts, daemon binary
nuke:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Resetting DB (drop/create/migrate)..."
    cd server
    if ! mix ecto.drop --force; then
      echo "Drop failed, terminating active DB sessions and retrying..."
      mix run -e '
        alias Algedonia.Repo
        db = Repo.query!("SELECT current_database()", []).rows |> hd() |> hd()
        Repo.query!(
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
          [db]
        )
      '
      mix ecto.drop --force
    fi
    mix ecto.create
    mix ecto.migrate
    echo "Clearing all application tables..."
    mix run -e '
      alias Algedonia.Repo

      tables =
        Repo.query!(
          "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() AND tablename <> $1",
          ["schema_migrations"]
        ).rows
        |> Enum.map(&hd/1)

      if tables != [] do
        joined = Enum.map_join(tables, ", ", &"\"#{&1}\"")
        Repo.query!("TRUNCATE TABLE " <> joined <> " RESTART IDENTITY CASCADE", [])
      end
    '
    cd ..
    echo "Removing project .algedonia runtime artifacts..."
    rm -rf .algedonia/runtime/ .algedonia/handoffs/
    echo "Removing user daemon state and config..."
    rm -rf ~/.algedonia/ ~/.config/ag/
    echo "Removing ag daemon binary..."
    rm -f ~/.local/bin/ag ~/bin/ag
    echo "Done. Clean slate."

# Build daemon for all platforms and upload to Supabase Storage
release-daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${SUPABASE_PROJECT_URL:?Set SUPABASE_PROJECT_URL}"
    : "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY}"
    DEFAULT_SERVER_WS_URL="${DAEMON_SERVER_WS_URL:-ws://localhost:4000/daemon/websocket}"
    TARGETS="darwin_amd64 darwin_arm64 linux_amd64 linux_arm64"
    for target in $TARGETS; do
        os="${target%_*}"
        arch="${target#*_}"
        filename="ag_${os}_${arch}.tar.gz"
        echo "Building $os/$arch..."
        cd daemon && CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -ldflags="-s -w -X main.defaultServerURL=${DEFAULT_SERVER_WS_URL}" -o ag ./cmd/algedonia-agent && cd ..
        tar czf "$filename" -C daemon ag
        rm daemon/ag
        echo "Uploading $filename..."
        curl -sSf -X POST \
            "${SUPABASE_PROJECT_URL}/storage/v1/object/releases/${filename}" \
            -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
            -H "Content-Type: application/gzip" \
            -H "x-upsert: true" \
            --data-binary "@${filename}"
        rm "$filename"
        echo " done"
    done
    echo "All daemon binaries uploaded."
