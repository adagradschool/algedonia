package adapter

import (
	"fmt"
	"os"
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

func signalTarget(sess *ptyPkg.Session) int {
	if pgid := sess.PGID(); pgid > 0 {
		return -pgid
	}
	return sess.Pid()
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	if errors, ok := err.(*os.SyscallError); ok {
		err = errors.Err
	}
	return err != syscall.ESRCH
}

// killProcess sends SIGTERM to the process group, waits gracePeriod, then SIGKILLs.
// It intentionally does not call Wait(): adapter wait goroutines own that lifecycle.
func killProcess(sess *ptyPkg.Session, gracePeriod time.Duration) error {
	pid := sess.Pid()
	if pid <= 0 {
		return nil
	}

	target := signalTarget(sess)
	_ = syscall.Kill(target, syscall.SIGTERM)

	deadline := time.Now().Add(gracePeriod)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			_ = sess.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}

	_ = syscall.Kill(target, syscall.SIGKILL)

	killDeadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(killDeadline) {
		if !processAlive(pid) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = sess.Close()
	return nil
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
