// Package pty manages pseudo-terminal allocation and I/O for agent processes.
package pty

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"

	"github.com/creack/pty"
)

// Session wraps a PTY-allocated child process.
type Session struct {
	master *os.File
	cmd    *exec.Cmd
}

// Start allocates a PTY and starts the command in it.
func Start(cmd *exec.Cmd) (*Session, error) {
	master, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("starting pty: %w", err)
	}

	return &Session{master: master, cmd: cmd}, nil
}

// Reader returns the master fd for reading child output.
func (s *Session) Reader() io.Reader {
	return s.master
}

// Write sends data to the child process stdin via the master fd.
func (s *Session) Write(data []byte) (int, error) {
	return s.master.Write(data)
}

// Close closes the master PTY fd.
func (s *Session) Close() error {
	return s.master.Close()
}

// Pid returns the child process PID.
func (s *Session) Pid() int {
	if s.cmd.Process == nil {
		return 0
	}
	return s.cmd.Process.Pid
}

// PGID returns the process group ID of the child.
func (s *Session) PGID() int {
	pid := s.Pid()
	if pid == 0 {
		return 0
	}
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		return pid
	}
	return pgid
}

// Wait waits for the child process to exit and returns the error (if any).
func (s *Session) Wait() error {
	return s.cmd.Wait()
}
