package repo

import "testing"

func TestAlternateURL(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		want   string
		wantOK bool
	}{
		{
			name:   "HTTPS to SSH",
			input:  "https://github.com/owner/repo.git",
			want:   "git@github.com:owner/repo.git",
			wantOK: true,
		},
		{
			name:   "HTTPS without .git to SSH",
			input:  "https://github.com/owner/repo",
			want:   "git@github.com:owner/repo.git",
			wantOK: true,
		},
		{
			name:   "SSH to HTTPS",
			input:  "git@github.com:owner/repo.git",
			want:   "https://github.com/owner/repo.git",
			wantOK: true,
		},
		{
			name:   "SSH without .git to HTTPS",
			input:  "git@github.com:owner/repo",
			want:   "https://github.com/owner/repo.git",
			wantOK: true,
		},
		{
			name:   "non-GitHub HTTPS",
			input:  "https://gitlab.com/owner/repo.git",
			want:   "",
			wantOK: false,
		},
		{
			name:   "non-GitHub SSH",
			input:  "git@gitlab.com:owner/repo.git",
			want:   "",
			wantOK: false,
		},
		{
			name:   "local file path",
			input:  "/tmp/repos/origin.git",
			want:   "",
			wantOK: false,
		},
		{
			name:   "file URL",
			input:  "file:///tmp/repos/origin.git",
			want:   "",
			wantOK: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := alternateURL(tt.input)
			if ok != tt.wantOK {
				t.Errorf("alternateURL(%q) ok = %v, want %v", tt.input, ok, tt.wantOK)
			}
			if got != tt.want {
				t.Errorf("alternateURL(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestURLsEquivalent(t *testing.T) {
	tests := []struct {
		name string
		a, b string
		want bool
	}{
		{
			name: "identical HTTPS",
			a:    "https://github.com/owner/repo.git",
			b:    "https://github.com/owner/repo.git",
			want: true,
		},
		{
			name: "HTTPS with and without .git",
			a:    "https://github.com/owner/repo.git",
			b:    "https://github.com/owner/repo",
			want: true,
		},
		{
			name: "HTTPS vs SSH same repo",
			a:    "https://github.com/owner/repo.git",
			b:    "git@github.com:owner/repo.git",
			want: true,
		},
		{
			name: "SSH vs HTTPS same repo",
			a:    "git@github.com:owner/repo",
			b:    "https://github.com/owner/repo.git",
			want: true,
		},
		{
			name: "different repos",
			a:    "https://github.com/owner/repo-a.git",
			b:    "https://github.com/owner/repo-b.git",
			want: false,
		},
		{
			name: "different owners",
			a:    "https://github.com/alice/repo.git",
			b:    "https://github.com/bob/repo.git",
			want: false,
		},
		{
			name: "non-GitHub identical",
			a:    "https://gitlab.com/owner/repo.git",
			b:    "https://gitlab.com/owner/repo.git",
			want: true,
		},
		{
			name: "non-GitHub with and without .git",
			a:    "https://gitlab.com/owner/repo.git",
			b:    "https://gitlab.com/owner/repo",
			want: true,
		},
		{
			name: "non-GitHub different protocols",
			a:    "https://gitlab.com/owner/repo.git",
			b:    "git@gitlab.com:owner/repo.git",
			want: false,
		},
		{
			name: "local file paths identical",
			a:    "/tmp/repos/origin.git",
			b:    "/tmp/repos/origin.git",
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := urlsEquivalent(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("urlsEquivalent(%q, %q) = %v, want %v", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
