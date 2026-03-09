package adapter

// spawnEnv returns a copy of the base environment for spawned agent processes.
func spawnEnv(base []string) []string {
	return append([]string{}, base...)
}
