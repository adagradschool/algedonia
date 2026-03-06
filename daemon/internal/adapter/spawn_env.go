package adapter

// spawnEnv appends environment variables used only for spawned agent processes.
// These disable package-manager auto-update checks that can block initial prompt
// delivery during startup.
func spawnEnv(base []string) []string {
	env := append([]string{}, base...)
	env = append(env, "HOMEBREW_NO_AUTO_UPDATE=1")
	env = append(env, "NO_UPDATE_NOTIFIER=1")
	return env
}
