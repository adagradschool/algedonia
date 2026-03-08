package main

import "testing"

func TestDetectCLIProfile(t *testing.T) {
	tests := []struct {
		name      string
		invokedAs string
		want      cliProfile
	}{
		{name: "ag binary", invokedAs: "ag", want: agProfile},
		{name: "agd binary", invokedAs: "agd", want: agdProfile},
		{name: "unknown defaults to ag", invokedAs: "algedonia-agent", want: agProfile},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := detectCLIProfile(tc.invokedAs)
			if got != tc.want {
				t.Fatalf("detectCLIProfile(%q)=%+v, want %+v", tc.invokedAs, got, tc.want)
			}
		})
	}
}

func TestProfileArtifactsAreNamespaced(t *testing.T) {
	if agProfile.LaunchdLabel == agdProfile.LaunchdLabel {
		t.Fatalf("launchd labels must differ: %q", agProfile.LaunchdLabel)
	}
	if agProfile.SystemdServiceName == agdProfile.SystemdServiceName {
		t.Fatalf("systemd service names must differ: %q", agProfile.SystemdServiceName)
	}
	if agProfile.LogPrefix == agdProfile.LogPrefix {
		t.Fatalf("log prefixes must differ: %q", agProfile.LogPrefix)
	}
}
