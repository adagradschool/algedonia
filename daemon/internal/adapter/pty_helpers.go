package adapter

import (
	"errors"
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
// ESRCH (no such process) is treated as a non-error since the process is already gone.
func killProcess(sess *ptyPkg.Session, gracePeriod time.Duration) error {
	pid := sess.Pid()
	if pid <= 0 {
		return nil
	}

	target := signalTarget(sess)
	if err := signalProcess(target, syscall.SIGTERM); err != nil {
		_ = sess.Close()
		return fmt.Errorf("sending SIGTERM: %w", err)
	}

	deadline := time.Now().Add(gracePeriod)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			_ = sess.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}

	if err := signalProcess(target, syscall.SIGKILL); err != nil {
		_ = sess.Close()
		return fmt.Errorf("sending SIGKILL: %w", err)
	}

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

// signalProcess sends a signal and treats ESRCH (no such process) and EPERM
// (permission denied, e.g. process group leader already exited on macOS) as
// non-errors, since both indicate the target is effectively gone.
func signalProcess(pid int, sig syscall.Signal) error {
	err := syscall.Kill(pid, sig)
	if err == nil {
		return nil
	}
	if isProcessGone(err) {
		return nil
	}
	return err
}

// isProcessGone returns true if the error indicates the process/group is
// already gone. On macOS, signaling a process group whose leader has exited
// returns EPERM rather than ESRCH, so both are treated as "gone".
func isProcessGone(err error) bool {
	return matchErrno(err, syscall.ESRCH) || matchErrno(err, syscall.EPERM)
}

func matchErrno(err error, target syscall.Errno) bool {
	if errors.Is(err, target) {
		return true
	}
	var se *os.SyscallError
	if errors.As(err, &se) {
		return errors.Is(se.Err, target)
	}
	return false
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
