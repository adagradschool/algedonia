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
					"tickets": []Ticket{{ID: "t1", Number: 1, Title: "Test"}},
				})
			})

			tickets, err := client.ListTickets(tt.opts)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(tickets) != 1 {
				t.Fatalf("expected 1 ticket, got %d", len(tickets))
			}
			if tickets[0].ID != "t1" {
				t.Errorf("ticket ID = %q, want %q", tickets[0].ID, "t1")
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
			"ticket": Ticket{ID: "uuid1", Number: 42, Title: "My ticket"},
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
			"ticket": Ticket{ID: "new1", Number: 1, Title: "New ticket"},
		})
	})

	ticket, err := client.CreateTicket(map[string]interface{}{
		"title": "New ticket",
		"type":  "feature",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ticket.ID != "new1" {
		t.Errorf("ID = %q, want %q", ticket.ID, "new1")
	}
}

func TestUpdateTicket(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" {
			t.Errorf("method = %q, want PATCH", r.Method)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"ticket": Ticket{ID: "t1", Number: 1, Title: "Updated", Status: "in_progress"},
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
			"comments": []Comment{{ID: "c1", Author: "alice", Body: "hello"}},
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
			"comment": Comment{ID: "c2", Author: "bob", Body: "nice"},
		})
	})

	comment, err := client.CreateComment("1", map[string]interface{}{
		"author": "bob",
		"body":   "nice",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if comment.ID != "c2" {
		t.Errorf("ID = %q, want %q", comment.ID, "c2")
	}
}

func TestUpdateComment(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" {
			t.Errorf("method = %q, want PATCH", r.Method)
		}
		if r.URL.Path != "/api/w/my-ws/tickets/1/comments/c1" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/1/comments/c1", r.URL.Path)
		}
		var body struct {
			Comment map[string]interface{} `json:"comment"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Comment["body"] != "updated body" {
			t.Errorf("body = %v, want %q", body.Comment["body"], "updated body")
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"comment": Comment{ID: "c1", Author: "alice", Body: "updated body"},
		})
	})

	comment, err := client.UpdateComment("1", "c1", map[string]interface{}{
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
		if r.URL.Path != "/api/w/my-ws/tickets/1/comments/c1" {
			t.Errorf("path = %q, want /api/w/my-ws/tickets/1/comments/c1", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	err := client.DeleteComment("1", "c1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestListWorkspaces(t *testing.T) {
	_, client := testServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/workspaces" {
			t.Errorf("path = %q, want /api/workspaces", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"workspaces": []Workspace{{ID: 1, Name: "Test", Slug: "test", Prefix: "TST"}},
		})
	})

	workspaces, err := client.ListWorkspaces()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(workspaces) != 1 || workspaces[0].Slug != "test" {
		t.Errorf("unexpected workspaces: %+v", workspaces)
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
