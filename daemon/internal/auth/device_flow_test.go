package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestRequestDeviceCode(t *testing.T) {
	tests := []struct {
		name       string
		handler    http.HandlerFunc
		wantErr    bool
		wantCode   string
		errContain string
	}{
		{
			name: "happy path returns parsed struct",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(DeviceCodeResponse{
					DeviceCode:      "dc_test123",
					UserCode:        "ABCD-1234",
					VerificationURI: "https://github.com/login/device",
					ExpiresIn:       900,
					Interval:        5,
				})
			},
			wantCode: "dc_test123",
		},
		{
			name: "server error returns wrapped error",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(500)
				w.Write([]byte("internal error"))
			},
			wantErr:    true,
			errContain: "500",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(tt.handler))
			defer srv.Close()

			df := &DeviceFlow{
				HTTPClient:    srv.Client(),
				ServerBaseURL: srv.URL,
			}

			resp, err := df.RequestDeviceCode()
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errContain != "" && !contains(err.Error(), tt.errContain) {
					t.Errorf("error %q should contain %q", err.Error(), tt.errContain)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resp.DeviceCode != tt.wantCode {
				t.Errorf("DeviceCode = %q, want %q", resp.DeviceCode, tt.wantCode)
			}
		})
	}
}

func TestPollForToken(t *testing.T) {
	tests := []struct {
		name       string
		handler    http.HandlerFunc
		sleepCount *int64
		wantToken  string
		wantErr    bool
		errContain string
		ctxFunc    func() (context.Context, context.CancelFunc)
		interval   int
		expiresIn  int
	}{
		{
			name: "immediate success returns token",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok_success"})
			},
			wantToken: "tok_success",
			interval:  1,
			expiresIn: 30,
		},
		{
			name: "pending then success polls multiple times",
			handler: func() http.HandlerFunc {
				var count int64
				return func(w http.ResponseWriter, r *http.Request) {
					n := atomic.AddInt64(&count, 1)
					w.Header().Set("Content-Type", "application/json")
					if n < 3 {
						json.NewEncoder(w).Encode(PollResponse{Status: "pending", Reason: "authorization_pending"})
					} else {
						json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok_after_pending"})
					}
				}
			}(),
			wantToken: "tok_after_pending",
			interval:  1,
			expiresIn: 30,
		},
		{
			name: "slow_down increases interval",
			handler: func() http.HandlerFunc {
				var count int64
				return func(w http.ResponseWriter, r *http.Request) {
					n := atomic.AddInt64(&count, 1)
					w.Header().Set("Content-Type", "application/json")
					if n == 1 {
						json.NewEncoder(w).Encode(PollResponse{Status: "pending", Reason: "slow_down"})
					} else {
						json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok_slowed"})
					}
				}
			}(),
			wantToken: "tok_slowed",
			interval:  1,
			expiresIn: 30,
		},
		{
			name: "expiry returns timeout error",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(PollResponse{Status: "pending", Reason: "authorization_pending"})
			},
			wantErr:    true,
			errContain: "expired",
			interval:   1,
			expiresIn:  1,
		},
		{
			name: "context cancellation stops polling",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(PollResponse{Status: "pending", Reason: "authorization_pending"})
			},
			ctxFunc: func() (context.Context, context.CancelFunc) {
				return context.WithCancel(context.Background())
			},
			wantErr:    true,
			errContain: "cancelled",
			interval:   1,
			expiresIn:  60,
		},
		{
			name: "server error returns wrapped error",
			handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(PollResponse{Status: "error", Error: "access_denied"})
			},
			wantErr:    true,
			errContain: "access_denied",
			interval:   1,
			expiresIn:  30,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(tt.handler))
			defer srv.Close()

			var sleepCalls int64
			cancelAfterSleep := false
			var cancelFunc context.CancelFunc

			ctx := context.Background()
			if tt.ctxFunc != nil {
				ctx, cancelFunc = tt.ctxFunc()
				cancelAfterSleep = true
			}

			df := &DeviceFlow{
				HTTPClient:    srv.Client(),
				ServerBaseURL: srv.URL,
				SleepFunc: func(d time.Duration) {
					n := atomic.AddInt64(&sleepCalls, 1)
					if cancelAfterSleep && n >= 1 && cancelFunc != nil {
						cancelFunc()
					}
				},
			}

			token, err := df.PollForToken(ctx, "dc_test", tt.interval, tt.expiresIn)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errContain != "" && !contains(err.Error(), tt.errContain) {
					t.Errorf("error %q should contain %q", err.Error(), tt.errContain)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if token != tt.wantToken {
				t.Errorf("token = %q, want %q", token, tt.wantToken)
			}
		})
	}
}

func TestPollForTokenSlowDownIncreasesInterval(t *testing.T) {
	var intervals []time.Duration
	var count int64

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt64(&count, 1)
		w.Header().Set("Content-Type", "application/json")
		if n == 1 {
			json.NewEncoder(w).Encode(PollResponse{Status: "pending", Reason: "slow_down"})
		} else {
			json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok"})
		}
	}))
	defer srv.Close()

	df := &DeviceFlow{
		HTTPClient:    srv.Client(),
		ServerBaseURL: srv.URL,
		SleepFunc: func(d time.Duration) {
			intervals = append(intervals, d)
		},
	}

	_, err := df.PollForToken(context.Background(), "dc", 1, 60)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(intervals) < 2 {
		t.Fatalf("expected at least 2 sleep calls, got %d", len(intervals))
	}

	// First sleep at 1s, second at 1s + 5s = 6s after slow_down
	if intervals[1] <= intervals[0] {
		t.Errorf("interval did not increase after slow_down: %v then %v", intervals[0], intervals[1])
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func TestRequestDeviceCode_InvalidJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte(`not valid json`))
	}))
	defer srv.Close()

	df := &DeviceFlow{
		HTTPClient:    srv.Client(),
		ServerBaseURL: srv.URL,
	}

	_, err := df.RequestDeviceCode()
	if err == nil {
		t.Fatal("expected error for invalid JSON, got nil")
	}
	if !contains(err.Error(), "parsing response") {
		t.Errorf("error %q should contain %q", err.Error(), "parsing response")
	}
}

func TestPollForToken_InvalidJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte(`{not json`))
	}))
	defer srv.Close()

	df := &DeviceFlow{
		HTTPClient:    srv.Client(),
		ServerBaseURL: srv.URL,
		SleepFunc:     func(d time.Duration) {},
	}

	_, err := df.PollForToken(context.Background(), "dc", 1, 30)
	if err == nil {
		t.Fatal("expected error for invalid JSON, got nil")
	}
	if !contains(err.Error(), "parsing poll response") {
		t.Errorf("error %q should contain %q", err.Error(), "parsing poll response")
	}
}

func TestPollForToken_UnknownStatusNon202(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		json.NewEncoder(w).Encode(PollResponse{Status: "unknown_status"})
	}))
	defer srv.Close()

	df := &DeviceFlow{
		HTTPClient:    srv.Client(),
		ServerBaseURL: srv.URL,
		SleepFunc:     func(d time.Duration) {},
	}

	_, err := df.PollForToken(context.Background(), "dc", 1, 30)
	if err == nil {
		t.Fatal("expected error for unknown status with non-202, got nil")
	}
	if !contains(err.Error(), "unexpected poll response") {
		t.Errorf("error %q should contain %q", err.Error(), "unexpected poll response")
	}
}

func TestPollForToken_UnknownStatus202Continues(t *testing.T) {
	var count int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt64(&count, 1)
		w.Header().Set("Content-Type", "application/json")
		if n == 1 {
			w.WriteHeader(202)
			json.NewEncoder(w).Encode(PollResponse{Status: "unknown_but_202"})
		} else {
			json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok_after_202"})
		}
	}))
	defer srv.Close()

	df := &DeviceFlow{
		HTTPClient:    srv.Client(),
		ServerBaseURL: srv.URL,
		SleepFunc:     func(d time.Duration) {},
	}

	token, err := df.PollForToken(context.Background(), "dc", 1, 30)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if token != "tok_after_202" {
		t.Errorf("token = %q, want %q", token, "tok_after_202")
	}
}

func TestPollForToken_NetworkError(t *testing.T) {
	// Create server and immediately close to simulate network failure
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close()

	df := &DeviceFlow{
		HTTPClient:    &http.Client{Timeout: 1 * time.Second},
		ServerBaseURL: url,
		SleepFunc:     func(d time.Duration) {},
	}

	_, err := df.PollForToken(context.Background(), "dc", 1, 30)
	if err == nil {
		t.Fatal("expected error for network failure, got nil")
	}
	if !contains(err.Error(), "polling for token") {
		t.Errorf("error %q should contain %q", err.Error(), "polling for token")
	}
}

func TestNewDeviceFlow(t *testing.T) {
	df := NewDeviceFlow("http://example.com")
	if df.HTTPClient == nil {
		t.Error("HTTPClient should not be nil")
	}
	if df.HTTPClient.Timeout == 0 {
		t.Error("HTTPClient.Timeout should be non-zero")
	}
	if df.SleepFunc == nil {
		t.Error("SleepFunc should not be nil")
	}
	if df.ServerBaseURL != "http://example.com" {
		t.Errorf("ServerBaseURL = %q, want %q", df.ServerBaseURL, "http://example.com")
	}
}

// Verify the backward-compatible package-level functions still work.
func TestPackageLevelFunctions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/auth/device/code":
			json.NewEncoder(w).Encode(DeviceCodeResponse{
				DeviceCode: "dc_compat",
				UserCode:   "TEST-CODE",
				ExpiresIn:  900,
				Interval:   5,
			})
		case "/api/auth/device/poll":
			json.NewEncoder(w).Encode(PollResponse{Status: "ok", Token: "tok_compat"})
		default:
			w.WriteHeader(404)
			fmt.Fprintf(w, "not found: %s", r.URL.Path)
		}
	}))
	defer srv.Close()

	resp, err := RequestDeviceCode(srv.URL)
	if err != nil {
		t.Fatalf("RequestDeviceCode: %v", err)
	}
	if resp.DeviceCode != "dc_compat" {
		t.Errorf("DeviceCode = %q, want %q", resp.DeviceCode, "dc_compat")
	}

	token, err := PollForToken(srv.URL, "dc_compat", 1, 30)
	if err != nil {
		t.Fatalf("PollForToken: %v", err)
	}
	if token != "tok_compat" {
		t.Errorf("token = %q, want %q", token, "tok_compat")
	}
}
