package main

import (
	"testing"

	"github.com/algedonia/daemon/internal/apiclient"
)

func TestResolveBlockedByParsing(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantN   int
		wantErr bool
	}{
		{"empty string returns empty slice", "", 0, false},
		{"whitespace only returns empty slice", "  ", 0, false},
		{"single number", "5", 1, false},
		{"multiple numbers", "1,2,3", 3, false},
		{"numbers with spaces", " 1 , 2 , 3 ", 3, false},
		{"trailing comma ignored", "1,2,", 2, false},
		{"non-numeric returns error", "abc", 0, true},
		{"mixed valid and invalid", "1,abc", 0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// We can't call resolveBlockedBy directly without a real client,
			// but we can test parseBlockedByNumbers which is the parsing logic.
			numbers, err := parseBlockedByNumbers(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(numbers) != tt.wantN {
				t.Errorf("expected %d numbers, got %d: %v", tt.wantN, len(numbers), numbers)
			}
		})
	}
}

func TestFormatBlockers(t *testing.T) {
	lookup := map[string]*apiclient.Ticket{
		"aaa": {ID: "aaa", Number: 1, Title: "Setup CI"},
		"bbb": {ID: "bbb", Number: 5, Title: "Add auth"},
	}

	tests := []struct {
		name      string
		blockedBy []string
		want      string
	}{
		{"nil returns None", nil, "None"},
		{"empty returns None", []string{}, "None"},
		{"single blocker", []string{"aaa"}, "#1 Setup CI"},
		{"multiple blockers", []string{"aaa", "bbb"}, "#1 Setup CI, #5 Add auth"},
		{"unknown ID falls back to raw ID", []string{"unknown-id"}, "unknown-id"},
		{"mixed known and unknown", []string{"aaa", "unknown"}, "#1 Setup CI, unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatBlockers(tt.blockedBy, lookup)
			if got != tt.want {
				t.Errorf("formatBlockers() = %q, want %q", got, tt.want)
			}
		})
	}
}
