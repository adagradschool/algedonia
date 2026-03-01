package terminalws

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAPITokenVerifier(t *testing.T) {
	tests := []struct {
		name       string
		handler    http.HandlerFunc
		wantErr    bool
		errContain string
	}{
		{
			name: "200 success returns nil",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			},
			wantErr: false,
		},
		{
			name: "401 error returns error with status",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusUnauthorized)
			},
			wantErr:    true,
			errContain: "401",
		},
		{
			name: "auth header sent correctly",
			handler: func(w http.ResponseWriter, r *http.Request) {
				auth := r.Header.Get("Authorization")
				if auth != "Bearer test-token-123" {
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				ct := r.Header.Get("Content-Type")
				if ct != "application/json" {
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				w.WriteHeader(http.StatusOK)
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(tt.handler)
			defer srv.Close()

			v := NewAPITokenVerifier(srv.URL, "test-token-123")
			v.httpClient = srv.Client()

			err := v.Verify(context.Background(), "ws-token", "loop-1")
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errContain != "" && !containsStr(err.Error(), tt.errContain) {
					t.Errorf("error %q should contain %q", err.Error(), tt.errContain)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestAPITokenVerifier_OtherErrorCodes(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
	}{
		{"403 forbidden", http.StatusForbidden},
		{"500 internal server error", http.StatusInternalServerError},
		{"503 service unavailable", http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.statusCode)
			}))
			defer srv.Close()

			v := NewAPITokenVerifier(srv.URL, "token")
			v.httpClient = srv.Client()

			err := v.Verify(context.Background(), "ws-token", "loop-1")
			if err == nil {
				t.Fatalf("expected error for status %d, got nil", tt.statusCode)
			}
			if !containsStr(err.Error(), fmt.Sprintf("%d", tt.statusCode)) {
				t.Errorf("error %q should contain status code %d", err.Error(), tt.statusCode)
			}
		})
	}
}

func TestAPITokenVerifier_WhitespaceTrimming(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	v := NewAPITokenVerifier("  "+srv.URL+"  ", "  my-token  ")
	v.httpClient = srv.Client()

	err := v.Verify(context.Background(), "ws-token", "loop-1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotAuth != "Bearer my-token" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer my-token")
	}
}

func TestAPITokenVerifier_NetworkFailure(t *testing.T) {
	// Create a server and immediately close it to simulate network failure
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close()

	v := NewAPITokenVerifier(url, "token")
	err := v.Verify(context.Background(), "ws-token", "loop-1")
	if err == nil {
		t.Fatal("expected error for network failure, got nil")
	}
	if !containsStr(err.Error(), "verify token request failed") {
		t.Errorf("error %q should indicate request failure", err.Error())
	}
}

func containsStr(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
