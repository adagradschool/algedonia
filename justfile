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
