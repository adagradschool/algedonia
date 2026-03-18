package apiclient

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *Client) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	client := New(srv.URL, "test-token", "my-ws")
	return srv, client
}

func TestDo_SetsHeaders(t *testing.T) {
	var gotAuth, gotAccept, gotContentType string
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotAccept = r.Header.Get("Accept")
		gotContentType = r.Header.Get("Content-Type")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	})

	_ = client.post("/test", map[string]string{"key": "val"}, nil)

	if gotAuth != "Bearer test-token" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer test-token")
	}
	if gotAccept != "application/json" {
		t.Errorf("Accept = %q, want %q", gotAccept, "application/json")
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want %q", gotContentType, "application/json")
	}
}

func TestDo_NoContentTypeOnGET(t *testing.T) {
	var gotContentType string
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		gotContentType = r.Header.Get("Content-Type")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	})

	_ = client.get("/test", nil)

	if gotContentType != "" {
		t.Errorf("Content-Type on GET = %q, want empty", gotContentType)
	}
}

func TestDo_APIError(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"not found"}`))
	})

	err := client.get("/missing", nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	apiErr, ok := err.(*APIError)
	if !ok {
		t.Fatalf("expected *APIError, got %T", err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("StatusCode = %d, want 404", apiErr.StatusCode)
	}
	if apiErr.Body != `{"error":"not found"}` {
		t.Errorf("Body = %q, want %q", apiErr.Body, `{"error":"not found"}`)
	}
}

func TestDo_ParsesResponse(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"name": "test"})
	})

	var out struct {
		Name string `json:"name"`
	}
	err := client.get("/test", &out)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.Name != "test" {
		t.Errorf("Name = %q, want %q", out.Name, "test")
	}
}

func TestListTickets(t *testing.T) {
	tests := []struct {
		name     string
		opts     ListTicketsOpts
		wantPath string
	}{
		{
			name:     "no filters",
			opts:     ListTicketsOpts{},
			wantPath: "/api/w/my-ws/tickets",
		},
		{
			name:     "status filter",
			opts:     ListTicketsOpts{Status: "backlog"},
			wantPath: "/api/w/my-ws/tickets?status=backlog",
		},
		{
			name:     "type filter",
			opts:     ListTicketsOpts{Type: "bug"},
			wantPath: "/api/w/my-ws/tickets?type=bug",
		},
		{
			name:     "priority filter",
			opts:     ListTicketsOpts{Priority: "1"},
			wantPath: "/api/w/my-ws/tickets?priority=1",
		},
		{
			name: "all filters",
			opts: ListTicketsOpts{
				Status:    "in_progress",
				Type:      "feature",
				Priority:  "2",
				Assignee:  "alice",
				SortBy:    "priority",
				SortOrder: "asc",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotPath string
			_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
				gotPath = r.URL.String()
				w.WriteHeader(http.StatusOK)
				_ = json.NewEncoder(w).Encode(map[string]interface{}{
					"tickets": []Ticket{{ID: "11111111-1111-4111-8111-111111111111", Number: 1, Title: "Test"}},
				})
			})

			tickets, err := client.ListTickets(tt.opts)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(tickets) != 1 {
				t.Fatalf("expected 1 ticket, got %d", len(tickets))
			}
			if tickets[0].ID != "11111111-1111-4111-8111-111111111111" {
				t.Errorf("ticket ID = %q, want %q", tickets[0].ID, "11111111-1111-4111-8111-111111111111")
			}

			// Check path only for simple cases where query order is predictable
			if tt.wantPath != "" && gotPath != tt.wantPath {
				t.Errorf("path = %q, want %q", gotPath, tt.wantPath)
			}

			// For "all filters", just verify all params are present
			if tt.name == "all filters" {
				for _, param := range []string{"status=in_progress", "type=feature", "priority=2", "assignee=alice", "sort_by=priority", "sort_order=asc"} {
					if !contains(gotPath, param) {
						t.Errorf("path %q missing param %q", gotPath, param)
					}
				}
			}
		})
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstr(s, substr))
}

func containsSubstr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func TestGetTicket(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/42" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/42", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"ticket": Ticket{ID: "22222222-2222-4222-8222-222222222222", Number: 42, Title: "My ticket"},
		})
	})

	ticket, err := client.GetTicket("42")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ticket.Number != 42 {
		t.Errorf("Number = %d, want 42", ticket.Number)
	}
}

func TestCreateTicket(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("method = %q, want POST", r.Method)
		}
		var body struct {
			Ticket map[string]interface{} `json:"ticket"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Ticket["title"] != "New ticket" {
			t.Errorf("title = %v, want %q", body.Ticket["title"], "New ticket")
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"ticket": Ticket{ID: "33333333-3333-4333-8333-333333333333", Number: 1, Title: "New ticket"},
		})
	})

	ticket, err := client.CreateTicket(map[string]interface{}{
		"title": "New ticket",
		"type":  "feature",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ticket.ID != "33333333-3333-4333-8333-333333333333" {
		t.Errorf("ID = %q, want %q", ticket.ID, "33333333-3333-4333-8333-333333333333")
	}
}

func TestUpdateTicket(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" {
			t.Errorf("method = %q, want PATCH", r.Method)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"ticket": Ticket{ID: "44444444-4444-4444-8444-444444444444", Number: 1, Title: "Updated", Status: "in_progress"},
		})
	})

	ticket, err := client.UpdateTicket("1", map[string]interface{}{"status": "in_progress"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ticket.Status != "in_progress" {
		t.Errorf("Status = %q, want %q", ticket.Status, "in_progress")
	}
}

func TestDeleteTicket(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" {
			t.Errorf("method = %q, want DELETE", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/5" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/5", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	err := client.DeleteTicket("5")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestListComments(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/w/my-ws/tickets/3/comments" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/3/comments", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"comments": []Comment{{ID: "55555555-5555-4555-8555-555555555555", Author: "alice", Body: "hello"}},
		})
	})

	comments, err := client.ListComments("3")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(comments) != 1 || comments[0].Author != "alice" {
		t.Errorf("unexpected comments: %+v", comments)
	}
}

func TestCreateComment(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("method = %q, want POST", r.Method)
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"comment": Comment{ID: "66666666-6666-4666-8666-666666666666", Author: "bob", Body: "nice"},
		})
	})

	comment, err := client.CreateComment("1", map[string]interface{}{
		"author": "bob",
		"body":   "nice",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if comment.ID != "66666666-6666-4666-8666-666666666666" {
		t.Errorf("ID = %q, want %q", comment.ID, "66666666-6666-4666-8666-666666666666")
	}
}

func TestUpdateComment(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" {
			t.Errorf("method = %q, want PATCH", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/1/comments/77777777-7777-4777-8777-777777777777" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/1/comments/77777777-7777-4777-8777-777777777777", r.URL.Path)
		}
		var body struct {
			Comment map[string]interface{} `json:"comment"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Comment["body"] != "updated body" {
			t.Errorf("body = %v, want %q", body.Comment["body"], "updated body")
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"comment": Comment{ID: "77777777-7777-4777-8777-777777777777", Author: "alice", Body: "updated body"},
		})
	})

	comment, err := client.UpdateComment("1", "77777777-7777-4777-8777-777777777777", map[string]interface{}{
		"body": "updated body",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if comment.Body != "updated body" {
		t.Errorf("Body = %q, want %q", comment.Body, "updated body")
	}
}

func TestDeleteComment(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" {
			t.Errorf("method = %q, want DELETE", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/1/comments/88888888-8888-4888-8888-888888888888" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/1/comments/88888888-8888-4888-8888-888888888888", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	err := client.DeleteComment("1", "88888888-8888-4888-8888-888888888888")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestListWorkspaces(t *testing.T) {
	tests := []struct {
		name   string
		rawID  interface{}
		wantID WorkspaceID
	}{
		{
			name:   "uuid string ids decode",
			rawID:  "550e8400-e29b-41d4-a716-446655440000",
			wantID: WorkspaceID("550e8400-e29b-41d4-a716-446655440000"),
		},
		{
			name:   "numeric ids remain supported",
			rawID:  1,
			wantID: WorkspaceID("1"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/workspaces" {
					t.Errorf("path = %q, want /api/workspaces", r.URL.Path)
				}
				_ = json.NewEncoder(w).Encode(map[string]interface{}{
					"workspaces": []map[string]interface{}{
						{"id": tt.rawID, "name": "Test", "slug": "test", "prefix": "TST"},
					},
				})
			})

			workspaces, err := client.ListWorkspaces()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(workspaces) != 1 {
				t.Fatalf("expected 1 workspace, got %d", len(workspaces))
			}
			if workspaces[0].ID != tt.wantID {
				t.Errorf("workspace ID = %q, want %q", workspaces[0].ID, tt.wantID)
			}
			if workspaces[0].Slug != "test" || workspaces[0].Name != "Test" {
				t.Errorf("unexpected workspaces: %+v", workspaces)
			}
		})
	}
}

func TestGetWorkspace(t *testing.T) {
	repoURL := "https://github.com/example/algedonia"
	bootstrap := "scripts/bootstrap.sh"
	runScript := "scripts/verify.sh"

	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/workspace" {
			t.Errorf("path = %q, want /api/w/my-ws/workspace", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspace": Workspace{
				ID:                      "workspace-1",
				Name:                    "Example",
				Slug:                    "example",
				Prefix:                  "EXA",
				GitHubRepoURL:           &repoURL,
				WorktreeBootstrapScript: &bootstrap,
				WorktreeRunScript:       &runScript,
				MaxIterations:           7,
			},
		})
	})

	workspace, err := client.GetWorkspace()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if workspace.Name != "Example" || workspace.Prefix != "EXA" {
		t.Fatalf("unexpected workspace: %+v", workspace)
	}
	if workspace.GitHubRepoURL == nil || *workspace.GitHubRepoURL != repoURL {
		t.Fatalf("github_repo_url = %v, want %q", workspace.GitHubRepoURL, repoURL)
	}
	if workspace.MaxIterations != 7 {
		t.Fatalf("max_iterations = %d, want 7", workspace.MaxIterations)
	}
}

func TestUpdateWorkspace(t *testing.T) {
	repoURL := "https://github.com/example/renamed"
	bootstrap := "scripts/bootstrap.sh"
	runScript := "scripts/verify.sh"

	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" {
			t.Errorf("method = %q, want PATCH", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/workspace" {
			t.Errorf("path = %q, want /api/w/my-ws/workspace", r.URL.Path)
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
		if body.Workspace["max_iterations"] != float64(9) {
			t.Fatalf("max_iterations = %v, want 9", body.Workspace["max_iterations"])
		}

		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspace": Workspace{
				ID:                      "workspace-1",
				Name:                    "Renamed Workspace",
				Slug:                    "renamed-workspace",
				Prefix:                  "REN",
				GitHubRepoURL:           &repoURL,
				WorktreeBootstrapScript: &bootstrap,
				WorktreeRunScript:       &runScript,
				MaxIterations:           9,
			},
		})
	})

	workspace, err := client.UpdateWorkspace(map[string]interface{}{
		"name":                      "Renamed Workspace",
		"max_iterations":            9,
		"github_repo_url":           repoURL,
		"worktree_bootstrap_script": bootstrap,
		"worktree_run_script":       runScript,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if workspace.Slug != "renamed-workspace" {
		t.Fatalf("slug = %q, want %q", workspace.Slug, "renamed-workspace")
	}
	if workspace.Prefix != "REN" {
		t.Fatalf("prefix = %q, want %q", workspace.Prefix, "REN")
	}
	if workspace.WorktreeRunScript == nil || *workspace.WorktreeRunScript != runScript {
		t.Fatalf("worktree_run_script = %v, want %q", workspace.WorktreeRunScript, runScript)
	}
}

func TestExportTicketMarkdown(t *testing.T) {
	wantMarkdown := "# #42: My ticket\n\n| Field | Value |\n"

	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Errorf("method = %q, want GET", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/42/export/markdown" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/42/export/markdown", r.URL.Path)
		}
		w.Header().Set("Content-Type", "text/markdown")
		w.Header().Set("Content-Disposition", `attachment; filename="42.md"`)
		_, _ = w.Write([]byte(wantMarkdown))
	})

	md, err := client.ExportTicketMarkdown("42")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if md != wantMarkdown {
		t.Errorf("markdown = %q, want %q", md, wantMarkdown)
	}
}

func TestExportTicketMarkdown_NotFound(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"ticket not found"}`))
	})

	_, err := client.ExportTicketMarkdown("999")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	apiErr, ok := err.(*APIError)
	if !ok {
		t.Fatalf("expected *APIError, got %T", err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("StatusCode = %d, want 404", apiErr.StatusCode)
	}
}

func TestNew_DefaultHTTPClientHasTimeout(t *testing.T) {
	client := New("http://example.com", "token", "ws")
	if client.HTTPClient == http.DefaultClient {
		t.Error("HTTPClient should not be http.DefaultClient")
	}
	if client.HTTPClient.Timeout == 0 {
		t.Error("HTTPClient.Timeout should be non-zero")
	}
}

func TestAPIError_Error(t *testing.T) {
	err := &APIError{StatusCode: 422, Body: `{"errors":{"title":["can't be blank"]}}`}
	got := err.Error()
	want := `api error (status 422): {"errors":{"title":["can't be blank"]}}`
	if got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
}
