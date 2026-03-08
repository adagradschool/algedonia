package main

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/algedonia/daemon/internal/config"
)

const (
	agServerWSFallback  = "ws://localhost:4000/daemon/websocket"
	agdServerWSFallback = "ws://localhost:4100/daemon/websocket"
)

type cliProfile struct {
	BinaryName              string
	ConfigProfile           string
	DefaultTerminalWSListen string
	LaunchdLabel            string
	SystemdServiceName      string
	LogPrefix               string
}

var (
	agProfile = cliProfile{
		BinaryName:              "ag",
		ConfigProfile:           "ag",
		DefaultTerminalWSListen: "127.0.0.1:8765",
		LaunchdLabel:            "com.algedonia.ag",
		SystemdServiceName:      "ag",
		LogPrefix:               "ag",
	}

	agdProfile = cliProfile{
		BinaryName:              "agd",
		ConfigProfile:           "agd",
		DefaultTerminalWSListen: "127.0.0.1:8766",
		LaunchdLabel:            "com.algedonia.agd",
		SystemdServiceName:      "agd",
		LogPrefix:               "agd",
	}

	activeProfile = agProfile
)

func detectCLIProfile(invokedAs string) cliProfile {
	name := strings.TrimSpace(filepath.Base(invokedAs))
	if name == agdProfile.BinaryName {
		return agdProfile
	}
	return agProfile
}

func initCLIProfile() {
	activeProfile = detectCLIProfile(os.Args[0])
	config.SetProfile(activeProfile.ConfigProfile)
}

func commandName() string {
	return activeProfile.BinaryName
}

func defaultTerminalWSListen() string {
	return activeProfile.DefaultTerminalWSListen
}

func fallbackServerWebsocketURL() string {
	if activeProfile.BinaryName == agdProfile.BinaryName {
		return agdServerWSFallback
	}
	return agServerWSFallback
}

func defaultServerWebsocketURL() string {
	if activeProfile.BinaryName == agdProfile.BinaryName {
		return agdServerWSFallback
	}
	return normalizeServerWebsocketURL(defaultServerURL)
}

func profileDefaultHTTPBaseURL() string {
	if activeProfile.BinaryName == agdProfile.BinaryName {
		return "http://localhost:4100"
	}
	return "http://localhost:4000"
}

func systemdUnitFileName() string {
	return activeProfile.SystemdServiceName + ".service"
}

func launchdPlistFileName() string {
	return activeProfile.LaunchdLabel + ".plist"
}
