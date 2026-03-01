package adapter

import (
	"io"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

func TestWaitProcessExitCode(t *testing.T) {
	tests := []struct {
		name     string
		command  string
		args     []string
		wantCode int
	}{
		{"exit 0", "true", nil, 0},
		{"exit 1", "false", nil, 1},
		{"exit 42", "sh", []string{"-c", "exit 42"}, 42},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd := exec.Command(tt.command, tt.args...)
			sess, err := allocatePTY(cmd)
			if err != nil {
				t.Fatalf("allocatePTY: %v", err)
			}

			// Drain PTY output to prevent blocking
			go io.Copy(io.Discard, sess.Reader())

			code, err := waitProcess(sess)
			if err != nil {
				t.Fatalf("waitProcess: %v", err)
			}
			if code != tt.wantCode {
				t.Errorf("exit code = %d, want %d", code, tt.wantCode)
			}
		})
	}
}

func TestKillProcessWithGracePeriod(t *testing.T) {
	cmd := exec.Command("sleep", "60")
	sess, err := allocatePTY(cmd)
	if err != nil {
		t.Fatalf("allocatePTY: %v", err)
	}

	// Drain PTY
	go io.Copy(io.Discard, sess.Reader())

	start := time.Now()
	err = killProcess(sess, 1*time.Second)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("killProcess: %v", err)
	}

	if elapsed > 3*time.Second {
		t.Errorf("killProcess took %v, expected < 3s", elapsed)
	}
}

func TestKillProcessAlreadyExited(t *testing.T) {
	// Start a process that exits quickly, then kill it.
	// This exercises the ESRCH path since the process is already dead.
	cmd := exec.Command("true")
	sess, err := allocatePTY(cmd)
	if err != nil {
		t.Fatalf("allocatePTY: %v", err)
	}

	go io.Copy(io.Discard, sess.Reader())

	// Wait for process to exit
	_ = sess.Wait()

	// Now kill should succeed gracefully (ESRCH treated as non-error)
	err = killProcess(sess, 1*time.Second)
	if err != nil {
		t.Errorf("killProcess on exited process: %v", err)
	}
}

func TestSignalProcess_ESRCH(t *testing.T) {
	// Use a PID that definitely doesn't exist
	// PID -1 is invalid for kill, so use a very large PID
	err := signalProcess(999999999, syscall.SIGTERM)
	// On most systems this returns ESRCH which should be treated as non-error
	if err != nil {
		t.Errorf("signalProcess on non-existent PID should return nil (ESRCH), got: %v", err)
	}
}

func TestAllocatePTY(t *testing.T) {
	cmd := exec.Command("echo", "hello")
	sess, err := allocatePTY(cmd)
	if err != nil {
		t.Fatalf("allocatePTY: %v", err)
	}

	pid := sess.Pid()
	if pid <= 0 {
		t.Errorf("Pid() = %d, want > 0", pid)
	}

	// Drain PTY
	go io.Copy(io.Discard, sess.Reader())

	code, err := waitProcess(sess)
	if err != nil {
		t.Fatalf("waitProcess: %v", err)
	}
	if code != 0 {
		t.Errorf("exit code = %d, want 0", code)
	}
}
