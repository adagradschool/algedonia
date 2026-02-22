# Build the daemon CLI as "ag" and install to PATH
build-cli:
    cd daemon && go build -o ag ./cmd/algedonia-agent
    mkdir -p ~/bin
    mv daemon/ag ~/bin/ag
