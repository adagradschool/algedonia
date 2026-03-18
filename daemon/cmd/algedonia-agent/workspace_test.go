package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/algedonia/daemon/internal/config"
)

func TestWorkspaceShowDisplaysCoreFields(t *testing.T) {
	repoURL := "https://github.com/example/algedonia"
	bootstrap := "scripts/bootstrap.sh"
	runScript := "scripts/verify.sh"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/w/scoped/workspace" {
			t.Fatalf("path = %q, want /api/w/scoped/workspace", r.URL.Path)
		}

		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspace": map[string]interface{}{
				"id":                        "workspace-1",
				"name":                      "Scoped Workspace",
				"slug":                      "scoped",
				"prefix":                    "SCO",
				"github_repo_url":           repoURL,
				"max_iterations":            7,
				"worktree_bootstrap_script": bootstrap,
				"worktree_run_script":       runScript,
				"tracker_config":            map[string]interface{}{"planning_states": []string{"planning"}},
				"playback_config":           map[string]interface{}{"concurrency": 2},
				"defaults":                  map[string]interface{}{"base_pipeline": []string{"test"}},
				"planning_mode":             "auto",
			},
		})
	}))
	t.Cleanup(srv.Close)

	setupWorkspaceCLITest(t, srv.URL, "scoped")

	stdout, stderr, err := executeWorkspaceCommand(t, "show", "--json")
	if err != nil {
		t.Fatalf("execute workspace show: %v\nstderr=%s", err, stderr)
	}

	var workspace map[string]interface{}
	if err := json.Unmarshal(stdout.Bytes(), &workspace); err != nil {
		t.Fatalf("decode stdout: %v\nstdout=%s", err, stdout.String())
	}

	if workspace["name"] != "Scoped Workspace" {
		t.Fatalf("name = %v, want %q", workspace["name"], "Scoped Workspace")
	}
	if workspace["prefix"] != "SCO" {
		t.Fatalf("prefix = %v, want %q", workspace["prefix"], "SCO")
	}
	if workspace["github_repo_url"] != repoURL {
		t.Fatalf("github_repo_url = %v, want %q", workspace["github_repo_url"], repoURL)
	}
	if workspace["max_iterations"] != float64(7) {
		t.Fatalf("max_iterations = %v, want 7", workspace["max_iterations"])
	}
	if workspace["worktree_bootstrap_script"] != bootstrap {
		t.Fatalf("worktree_bootstrap_script = %v, want %q", workspace["worktree_bootstrap_script"], bootstrap)
	}
	if workspace["worktree_run_script"] != runScript {
		t.Fatalf("worktree_run_script = %v, want %q", workspace["worktree_run_script"], runScript)
	}
}

func TestWorkspaceUpdatePersistsCoreFieldsAndRenamedWorkspace(t *testing.T) {
	repoURL := "https://github.com/example/renamed"
	bootstrap := "scripts/bootstrap.sh"
	runScript := "scripts/verify.sh"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch {
			t.Fatalf("method = %q, want PATCH", r.Method)
		}
		if r.URL.Path != "/api/w/scoped/workspace" {
			t.Fatalf("path = %q, want /api/w/scoped/workspace", r.URL.Path)
		}

		var body struct {
			Workspace map[string]interface{} `json:"workspace"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}

		if body.Workspace["name"] != "Renamed Workspace" {
			t.Fatalf("name = %v, want %q", body.Workspace["name"], "Renamed Workspace")
		}
		if body.Workspace["github_repo_url"] != repoURL {
			t.Fatalf("github_repo_url = %v, want %q", body.Workspace["github_repo_url"], repoURL)
		}
		if body.Workspace["max_iterations"] != float64(9) {
			t.Fatalf("max_iterations = %v, want 9", body.Workspace["max_iterations"])
		}
		if body.Workspace["worktree_bootstrap_script"] != bootstrap {
			t.Fatalf("worktree_bootstrap_script = %v, want %q", body.Workspace["worktree_bootstrap_script"], bootstrap)
		}
		if body.Workspace["worktree_run_script"] != runScript {
			t.Fatalf("worktree_run_script = %v, want %q", body.Workspace["worktree_run_script"], runScript)
		}

		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspace": map[string]interface{}{
				"id":                        "workspace-1",
				"name":                      "Renamed Workspace",
				"slug":                      "renamed-workspace",
				"prefix":                    "REN",
				"github_repo_url":           repoURL,
				"max_iterations":            9,
				"worktree_bootstrap_script": bootstrap,
				"worktree_run_script":       runScript,
			},
		})
	}))
	t.Cleanup(srv.Close)

	setupWorkspaceCLITest(t, srv.URL, "scoped")

	stdout, stderr, err := executeWorkspaceCommand(
		t,
		"update",
		"--name", "Renamed Workspace",
		"--github-repo-url", repoURL,
		"--max-iterations", "9",
		"--worktree-bootstrap-script", bootstrap,
		"--worktree-run-script", runScript,
		"--json",
	)
	if err != nil {
		t.Fatalf("execute workspace update: %v\nstderr=%s", err, stderr)
	}

	var workspace map[string]interface{}
	if err := json.Unmarshal(stdout.Bytes(), &workspace); err != nil {
		t.Fatalf("decode stdout: %v\nstdout=%s", err, stdout.String())
	}

	if workspace["slug"] != "renamed-workspace" {
		t.Fatalf("slug = %v, want %q", workspace["slug"], "renamed-workspace")
	}
	if workspace["prefix"] != "REN" {
		t.Fatalf("prefix = %v, want %q", workspace["prefix"], "REN")
	}

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if cfg.Workspace != "renamed-workspace" {
		t.Fatalf("cfg.Workspace = %q, want %q", cfg.Workspace, "renamed-workspace")
	}
}

func TestWorkspaceUpdateCanPatchSingleScriptField(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch {
			t.Fatalf("method = %q, want PATCH", r.Method)
		}

		var body struct {
			Workspace map[string]interface{} `json:"workspace"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}

		if len(body.Workspace) != 1 {
			t.Fatalf("workspace payload = %#v, want only one field", body.Workspace)
		}
		if body.Workspace["worktree_run_script"] != "./scripts/check.sh --fast" {
			t.Fatalf("worktree_run_script = %v, want %q", body.Workspace["worktree_run_script"], "./scripts/check.sh --fast")
		}

		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspace": map[string]interface{}{
				"id":                        "workspace-1",
				"name":                      "Scoped Workspace",
				"slug":                      "scoped",
				"prefix":                    "SCO",
				"max_iterations":            7,
				"worktree_run_script":       "./scripts/check.sh --fast",
				"worktree_bootstrap_script": nil,
			},
		})
	}))
	t.Cleanup(srv.Close)

	setupWorkspaceCLITest(t, srv.URL, "scoped")

	stdout, stderr, err := executeWorkspaceCommand(
		t,
		"update",
		"--worktree-run-script", "./scripts/check.sh --fast",
		"--json",
	)
	if err != nil {
		t.Fatalf("execute workspace update: %v\nstderr=%s", err, stderr)
	}

	if !strings.Contains(stdout.String(), `"worktree_run_script": "./scripts/check.sh --fast"`) {
		t.Fatalf("stdout missing updated script:\n%s", stdout.String())
	}
}

func TestWorkspaceUpdateRejectsInvalidValues(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		response string
		wantErr  string
	}{
		{
			name:     "invalid github repo url",
			args:     []string{"update", "--github-repo-url", "github.com/example/repo"},
			response: `{"errors":{"github_repo_url":["Must be a valid URL starting with http:// or https://"]}}`,
			wantErr:  "github_repo_url (--github-repo-url): Must be a valid URL starting with http:// or https://",
		},
		{
			name:     "out of range max iterations",
			args:     []string{"update", "--max-iterations", "99"},
			response: `{"errors":{"max_iterations":["Must be less than or equal to 50"]}}`,
			wantErr:  "max_iterations (--max-iterations): Must be less than or equal to 50",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(tc.response))
			}))
			t.Cleanup(srv.Close)

			setupWorkspaceCLITest(t, srv.URL, "scoped")

			_, _, err := executeWorkspaceCommand(t, tc.args...)
			if err == nil {
				t.Fatal("expected error, got nil")
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error = %q, want substring %q", err.Error(), tc.wantErr)
			}
		})
	}
}

func TestWorkspaceListCmd_PrintsActiveWorkspaceForUUIDIDs(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	prevProfile := activeProfile
	activeProfile = agProfile
	config.SetProfile("ag")
	t.Cleanup(func() {
		activeProfile = prevProfile
		config.SetProfile("ag")
	})

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/workspaces" {
			t.Errorf("path = %q, want /api/workspaces", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("Authorization = %q, want %q", got, "Bearer test-token")
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspaces": []map[string]interface{}{
				{
					"id":     "550e8400-e29b-41d4-a716-446655440000",
					"slug":   "alpha",
					"name":   "Alpha",
					"prefix": "ALP",
				},
				{
					"id":     "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
					"slug":   "beta",
					"name":   "Beta",
					"prefix": "BET",
				},
			},
		})
	}))
	t.Cleanup(srv.Close)

	if err := config.Save(&config.Config{
		ServerURL: srv.URL,
		Token:     "test-token",
		Workspace: "beta",
	}); err != nil {
		t.Fatalf("config.Save: %v", err)
	}

	cmd := newWorkspaceListCmd()
	output, err := captureStdout(t, func() error {
		return cmd.RunE(cmd, nil)
	})
	if err != nil {
		t.Fatalf("workspace list returned error: %v", err)
	}

	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 output lines, got %d: %q", len(lines), output)
	}

	if got := strings.Fields(lines[0]); len(got) != 2 || got[0] != "alpha" || got[1] != "Alpha" {
		t.Fatalf("inactive workspace row = %q, want slug/name without marker", lines[0])
	}
	if got := strings.Fields(lines[1]); len(got) != 3 || got[0] != "*" || got[1] != "beta" || got[2] != "Beta" {
		t.Fatalf("active workspace row = %q, want marker/slug/name", lines[1])
	}
}

func executeWorkspaceCommand(t *testing.T, args ...string) (*bytes.Buffer, *bytes.Buffer, error) {
	t.Helper()

	workspaceTarget = ""
	t.Cleanup(func() {
		workspaceTarget = ""
	})

	cmd := newWorkspaceCmd()
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	cmd.SetOut(stdout)
	cmd.SetErr(stderr)
	cmd.SetArgs(args)

	return stdout, stderr, cmd.Execute()
}

func captureStdout(t *testing.T, run func() error) (string, error) {
	t.Helper()

	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}

	os.Stdout = w
	defer func() {
		os.Stdout = origStdout
	}()

	runErr := run()
	if err := w.Close(); err != nil {
		t.Fatalf("closing pipe writer: %v", err)
	}

	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("reading captured stdout: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("closing pipe reader: %v", err)
	}

	return string(out), runErr
}

func setupWorkspaceCLITest(t *testing.T, serverURL, workspace string) {
	t.Helper()

	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Setenv("ALGEDONIA_WORKSPACE", "")
	t.Setenv("ALGEDONIA_WORKSPACE_SLUG", "")

	prevProfile := activeProfile
	activeProfile = agProfile
	config.SetProfile("ag")
	t.Cleanup(func() {
		activeProfile = prevProfile
		config.SetProfile("ag")
	})

	if err := config.Save(&config.Config{
		ServerURL: serverURL,
		Token:     "test-token",
		Workspace: workspace,
	}); err != nil {
		t.Fatalf("config.Save: %v", err)
	}
}
