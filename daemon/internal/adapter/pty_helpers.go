package adapter

import (
	"fmt"
	"os/exec"
	"syscall"
	"time"

	ptyPkg "github.com/algedonia/daemon/internal/pty"
)

// allocatePTY starts cmd in a new PTY.
func allocatePTY(cmd *exec.Cmd) (*ptyPkg.Session, error) {
	sess, err := ptyPkg.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("allocating pty: %w", err)
	}
	return sess, nil
}

// killProcess sends SIGTERM to the process, waits gracePeriod, then SIGKILLs.
func killProcess(sess *ptyPkg.Session, gracePeriod time.Duration) error {
	pid := sess.Pid()
	if pid <= 0 {
		return nil
	}

	_ = syscall.Kill(pid, syscall.SIGTERM)

	// Wait for exit with timeout
	done := make(chan struct{})
	go func() {
		_ = sess.Wait()
		close(done)
	}()

	select {
	case <-done:
		sess.Close()
		return nil
	case <-time.After(gracePeriod):
		_ = syscall.Kill(pid, syscall.SIGKILL)
		<-done
		sess.Close()
		return nil
	}
}

// waitProcess waits for the process to exit and returns the exit code.
func waitProcess(sess *ptyPkg.Session) (int, error) {
	err := sess.Wait()
	sess.Close()
	if err == nil {
		return 0, nil
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		return exitErr.ExitCode(), nil
	}
	return -1, fmt.Errorf("waiting for process: %w", err)
}
