package repo

import (
	"regexp"
	"strings"
)

// sshPattern matches GitHub SSH URLs: git@github.com:owner/repo.git
var sshPattern = regexp.MustCompile(`^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$`)

// httpsPattern matches GitHub HTTPS URLs: https://github.com/owner/repo.git
var httpsPattern = regexp.MustCompile(`^https://github\.com/([^/]+/[^/]+?)(?:\.git)?$`)

// alternateURL converts a GitHub HTTPS URL to SSH or vice versa.
// Returns ("", false) for non-GitHub URLs.
func alternateURL(repoURL string) (string, bool) {
	repoURL = strings.TrimSpace(repoURL)

	if m := httpsPattern.FindStringSubmatch(repoURL); m != nil {
		return "git@github.com:" + m[1] + ".git", true
	}

	if m := sshPattern.FindStringSubmatch(repoURL); m != nil {
		return "https://github.com/" + m[1] + ".git", true
	}

	return "", false
}

// normalizeRepoURL strips trailing ".git" and whitespace for comparison.
func normalizeRepoURL(u string) string {
	u = strings.TrimSpace(u)
	u = strings.TrimSuffix(u, ".git")
	return u
}

// urlsEquivalent returns true if two repo URLs refer to the same GitHub
// repository, regardless of protocol (SSH vs HTTPS) or trailing .git.
func urlsEquivalent(a, b string) bool {
	a = strings.TrimSpace(a)
	b = strings.TrimSpace(b)

	if normalizeRepoURL(a) == normalizeRepoURL(b) {
		return true
	}

	// Check if one is the alternate of the other.
	alt, ok := alternateURL(a)
	if !ok {
		return false
	}
	return normalizeRepoURL(alt) == normalizeRepoURL(b)
}
