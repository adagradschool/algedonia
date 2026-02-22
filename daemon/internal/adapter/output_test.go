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

func TestParseDAGOutput(t *testing.T) {
	raw := []byte(`some preamble text
---ALGEDONIA_DAG_BEGIN---
{
  "loops": [
    {"id": "loop-1", "title": "Add model", "description": "Create model", "rubric": "Model exists", "path_hints": ["lib/model.ex"]},
    {"id": "loop-2", "title": "Add tests", "description": "Write tests", "rubric": "Tests pass", "path_hints": ["test/"]}
  ],
  "dependencies": [
    {"upstream": "loop-1", "downstream": "loop-2"}
  ]
}
---ALGEDONIA_DAG_END---
some epilogue`)

	dag, err := ParseDAGOutput(raw)
	if err != nil {
		t.Fatalf("ParseDAGOutput: %v", err)
	}

	if len(dag.Loops) != 2 {
		t.Fatalf("len(Loops) = %d, want 2", len(dag.Loops))
	}
	if dag.Loops[0].ID != "loop-1" {
		t.Errorf("Loops[0].ID = %q, want %q", dag.Loops[0].ID, "loop-1")
	}
	if dag.Loops[0].Title != "Add model" {
		t.Errorf("Loops[0].Title = %q, want %q", dag.Loops[0].Title, "Add model")
	}
	if len(dag.Loops[0].PathHints) != 1 || dag.Loops[0].PathHints[0] != "lib/model.ex" {
		t.Errorf("Loops[0].PathHints = %v, want [lib/model.ex]", dag.Loops[0].PathHints)
	}

	if len(dag.Dependencies) != 1 {
		t.Fatalf("len(Dependencies) = %d, want 1", len(dag.Dependencies))
	}
	if dag.Dependencies[0].Upstream != "loop-1" || dag.Dependencies[0].Downstream != "loop-2" {
		t.Errorf("Dependency = %+v, want {loop-1 -> loop-2}", dag.Dependencies[0])
	}
}

func TestParseDAGOutputWithANSI(t *testing.T) {
	raw := []byte("\x1b[32m---ALGEDONIA_DAG_BEGIN---\x1b[0m\n" +
		`{"loops":[{"id":"l1","title":"T","description":"D","rubric":"R","path_hints":[]}],"dependencies":[]}` +
		"\n\x1b[32m---ALGEDONIA_DAG_END---\x1b[0m")

	dag, err := ParseDAGOutput(raw)
	if err != nil {
		t.Fatalf("ParseDAGOutput with ANSI: %v", err)
	}
	if len(dag.Loops) != 1 {
		t.Errorf("len(Loops) = %d, want 1", len(dag.Loops))
	}
}

func TestParseDAGOutputMissingBeginDelimiter(t *testing.T) {
	raw := []byte(`{"loops":[]} ---ALGEDONIA_DAG_END---`)
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for missing begin delimiter")
	}
}

func TestParseDAGOutputMissingEndDelimiter(t *testing.T) {
	raw := []byte(`---ALGEDONIA_DAG_BEGIN--- {"loops":[]}`)
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for missing end delimiter")
	}
}

func TestParseDAGOutputInvalidJSON(t *testing.T) {
	raw := []byte("---ALGEDONIA_DAG_BEGIN---\nnot json\n---ALGEDONIA_DAG_END---")
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestParseDAGOutputNoLoops(t *testing.T) {
	raw := []byte(`---ALGEDONIA_DAG_BEGIN---
{"loops":[],"dependencies":[]}
---ALGEDONIA_DAG_END---`)
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for empty loops")
	}
}

func TestParseDAGOutputEmptyID(t *testing.T) {
	raw := []byte(`---ALGEDONIA_DAG_BEGIN---
{"loops":[{"id":"","title":"T","description":"D","rubric":"R","path_hints":[]}],"dependencies":[]}
---ALGEDONIA_DAG_END---`)
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for empty loop ID")
	}
}

func TestParseDAGOutputEmptyTitle(t *testing.T) {
	raw := []byte(`---ALGEDONIA_DAG_BEGIN---
{"loops":[{"id":"l1","title":"","description":"D","rubric":"R","path_hints":[]}],"dependencies":[]}
---ALGEDONIA_DAG_END---`)
	_, err := ParseDAGOutput(raw)
	if err == nil {
		t.Fatal("expected error for empty loop title")
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
