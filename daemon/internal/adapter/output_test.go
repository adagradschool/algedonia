package adapter

import (
	"bytes"
	"sync"
	"testing"
)

func TestStripANSI(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"plain text", "hello world", "hello world"},
		{"color codes", "\x1b[31mred\x1b[0m", "red"},
		{"bold", "\x1b[1mbold\x1b[0m", "bold"},
		{"multiple", "\x1b[32mgreen\x1b[0m and \x1b[34mblue\x1b[0m", "green and blue"},
		{"empty", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := string(StripANSI([]byte(tt.input)))
			if got != tt.want {
				t.Errorf("StripANSI(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestStripANSIStandalone(t *testing.T) {
	raw := []byte("\x1b[32mhello\x1b[0m")
	got := StripANSI(raw)
	if string(got) != "hello" {
		t.Fatalf("StripANSI = %q, want %q", string(got), "hello")
	}
}

func TestOutputCollectorConcurrent(t *testing.T) {
	c := newOutputCollector()
	var wg sync.WaitGroup

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				c.Write([]byte("x"))
			}
		}()
	}
	wg.Wait()

	got := c.Bytes()
	if len(got) != 1000 {
		t.Errorf("len(Bytes()) = %d, want 1000", len(got))
	}
	if !bytes.Equal(got, bytes.Repeat([]byte("x"), 1000)) {
		t.Error("unexpected content in collector")
	}
}
