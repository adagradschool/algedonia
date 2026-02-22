package pty

import (
	"bytes"
	"io"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestStartAndReadOutput(t *testing.T) {
	cmd := exec.Command("echo", "hello")
	sess, err := Start(cmd)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer sess.Close()

	var buf bytes.Buffer
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(&buf, sess.Reader())
		done <- err
	}()

	if err := sess.Wait(); err != nil {
		t.Fatalf("Wait: %v", err)
	}

	// Give reader goroutine time to drain
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("read timed out")
	}

	output := buf.String()
	if !strings.Contains(output, "hello") {
		t.Errorf("output = %q, want it to contain %q", output, "hello")
	}
}

func TestWriteToStdin(t *testing.T) {
	cmd := exec.Command("cat")
	sess, err := Start(cmd)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer sess.Close()

	// Write to cat's stdin
	_, err = sess.Write([]byte("ping\n"))
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	// Read output (cat echoes back)
	buf := make([]byte, 256)
	var output string
	deadline := time.After(2 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for output, got: %q", output)
		default:
		}
		n, err := sess.Reader().Read(buf)
		if n > 0 {
			output += string(buf[:n])
		}
		if strings.Contains(output, "ping") {
			break
		}
		if err != nil {
			t.Fatalf("Read: %v, output so far: %q", err, output)
		}
	}

	// Send EOF to terminate cat
	sess.Close()
}

func TestPidAndPGID(t *testing.T) {
	cmd := exec.Command("sleep", "10")
	sess, err := Start(cmd)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer sess.Close()

	pid := sess.Pid()
	if pid == 0 {
		t.Error("Pid() returned 0")
	}

	pgid := sess.PGID()
	if pgid == 0 {
		t.Error("PGID() returned 0")
	}

	// Clean up
	sess.Close()
	_ = sess.Wait()
}
