// Package loopmanager tracks running loop processes, owning PTY sessions and output streaming.
package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	ptyPkg "github.com/algedonia/daemon/internal/pty"
	"github.com/algedonia/daemon/internal/repo"
	"github.com/algedonia/daemon/internal/terminalstream"
)

// LoopProcess represents a running loop with its PTY session and chunker.
type LoopProcess struct {
	LoopID  string
	Session *ptyPkg.Session
	Chunker *Chunker
	Cancel  context.CancelFunc
	Done    chan struct{}

	mu      sync.Mutex
	stopped bool

	// adapter fields — set when started via StartLoopWithAdapter
	adapter      adapter.AgentAdapter
	process      *adapter.Process
	role         string
	promptsDir   string
	workdir      string
	workspaceDir string
	attempt      int
}

// Manager tracks running loop processes and streams their output.
type Manager struct {
	mu               sync.Mutex
	loops            map[string]*LoopProcess
	termSubs         map[string]map[uint64]chan terminalstream.Chunk
	termStream       map[string]*terminalStreamState
	nextSubID        uint64
	sendFunc         func(event string, payload map[string]interface{}) error
	adapterReg       *adapter.Registry
	repoRoot         string
	workspaceBaseDir string
	worktreeMgr      repo.WorktreeManager
	replayMax        int
}

const (
	defaultChunkFlushInterval = 50 * time.Millisecond
	defaultChunkMaxSize       = 4096
	defaultReplayMaxBytes     = 8 * 1024 * 1024
	minChunkFlushMS           = 1
	minChunkMaxBytes          = 256
	minReplayMaxBytes         = 64 * 1024
	// ptyReadBufSize is the buffer size for reading PTY/pipe output.
	ptyReadBufSize = 4096
)

// NewManager creates a Manager that uses sendFunc to send events to the server.
func NewManager(sendFunc func(event string, payload map[string]interface{}) error, registry *adapter.Registry, repoRoot string) *Manager {
	return &Manager{
		loops:      make(map[string]*LoopProcess),
		termSubs:   make(map[string]map[uint64]chan terminalstream.Chunk),
		termStream: make(map[string]*terminalStreamState),
		sendFunc:   sendFunc,
		adapterReg: registry,
		repoRoot:   repoRoot,
		replayMax:  replayMaxBytesFromEnv(os.Getenv),
	}
}

// SetWorkspaceBaseDir sets the base directory for workspace working directories.
func (m *Manager) SetWorkspaceBaseDir(dir string) {
	m.workspaceBaseDir = dir
}

// SetWorktreeManager sets the worktree manager for ticket-scoped worktrees.
func (m *Manager) SetWorktreeManager(wm repo.WorktreeManager) {
	m.worktreeMgr = wm
}

// workdirForWorkspace returns the working directory for a workspace slug.
// Falls back to repoRoot if no workspace base dir is set or slug is empty.
func (m *Manager) workdirForWorkspace(slug string) string {
	if slug != "" && m.workspaceBaseDir != "" {
		return filepath.Join(m.workspaceBaseDir, slug)
	}
	return m.repoRoot
}

func (m *Manager) sendEvent(event string, payload map[string]interface{}) {
	const maxAttempts = 5

	var err error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		err = m.sendFunc(event, payload)
		if err == nil {
			return
		}
		if attempt < maxAttempts {
			time.Sleep(time.Duration(attempt*100) * time.Millisecond)
		}
	}

	if err != nil {
		loopID, _ := payload["loop_id"].(string)
		log.Printf(
			"Failed to send %s event for loop %s after %d attempts: %v",
			event,
			loopID,
			maxAttempts,
			err,
		)
	}
}

func (m *Manager) newTerminalChunker(loopID string) *Chunker {
	flushInterval := chunkFlushIntervalFromEnv(os.Getenv)
	maxSize := chunkMaxSizeFromEnv(os.Getenv)

	return NewChunker(flushInterval, maxSize, func(data []byte) {
		encoded := base64.StdEncoding.EncodeToString(data)
		if err := m.sendFunc("terminal_output", map[string]interface{}{
			"loop_id": loopID,
			"data":    encoded,
		}); err != nil {
			log.Printf("Failed to send terminal_output for loop %s: %v", loopID, err)
		}
	})
}

// readOutputLoop reads from r in ptyReadBufSize chunks, writing to the chunker
// and optionally broadcasting to terminal subscribers via broadcastFn.
// It closes the chunker when the reader returns an error or EOF.
func readOutputLoop(r io.Reader, loopID string, chunker *Chunker, broadcastFn func(string, []byte)) {
	buf := make([]byte, ptyReadBufSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if broadcastFn != nil {
				broadcastFn(loopID, buf[:n])
			}
			chunker.Write(buf[:n])
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("PTY read error for loop %s: %v", loopID, err)
			}
			break
		}
	}
	chunker.Close()
}

// waitAndNotifyExit waits for a process to exit via waitFn, sends a loop_exited
// event with the exit code, removes the loop from the map, and closes done.
func (m *Manager) waitAndNotifyExit(loopID string, waitFn func() error, done chan struct{}) {
	defer close(done)
	waitErr := waitFn()

	exitCode := 0
	if waitErr != nil {
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = -1
		}
	}

	if err := m.sendFunc("loop_exited", map[string]interface{}{
		"loop_id":   loopID,
		"exit_code": exitCode,
	}); err != nil {
		log.Printf("Failed to send loop_exited for loop %s: %v", loopID, err)
	}

	m.mu.Lock()
	delete(m.loops, loopID)
	m.mu.Unlock()
}

// StartLoop spawns a process in a PTY and streams output to the server.
// If prompt is non-empty, it is written to the process stdin after startup.
func (m *Manager) StartLoop(ctx context.Context, loopID, command string, args []string, workdir, prompt string) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	loopCtx, cancel := context.WithCancel(ctx)

	cmd := exec.CommandContext(loopCtx, command, args...)
	if workdir != "" {
		cmd.Dir = workdir
	}

	sess, err := ptyPkg.Start(cmd)
	if err != nil {
		cancel()
		return fmt.Errorf("starting pty for loop %s: %w", loopID, err)
	}

	done := make(chan struct{})

	chunker := m.newTerminalChunker(loopID)

	lp := &LoopProcess{
		LoopID:  loopID,
		Session: sess,
		Chunker: chunker,
		Cancel:  cancel,
		Done:    done,
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()

	go readOutputLoop(sess.Reader(), loopID, chunker, m.broadcastTerminal)

	go m.waitAndNotifyExit(loopID, func() error {
		err := sess.Wait()
		sess.Close()
		return err
	}, done)

	if prompt != "" {
		writeFn := func(data []byte) error {
			_, err := sess.Write(data)
			return err
		}
		go sendPromptToTUI(done, loopID, prompt, writeFn)
	}

	log.Printf("Started loop %s: %s %v", loopID, command, args)
	return nil
}

// StartLoopWithAdapter spawns a loop using a registered adapter.
func (m *Manager) StartLoopWithAdapter(ctx context.Context, loopID, agentType, role, workdir, workspaceDir, workspaceSlug, taskDesc, model, effort string, attempt int) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	if attempt < 1 {
		attempt = 1
	}

	ag, err := m.adapterReg.Get(agentType)
	if err != nil {
		return fmt.Errorf("resolving adapter for loop %s: %w", loopID, err)
	}

	promptsDir := filepath.Join(workdir, ".algedonia", "prompts")
	task := buildAdapterTask(promptsDir, role, taskDesc)

	proc, reader, err := m.startAdapterProcess(ag, loopID, workdir, workspaceSlug, task, model, effort, role)
	if err != nil {
		return err
	}

	_, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	chunker := m.newTerminalChunker(loopID)
	lp := m.registerAdapterLoop(loopID, role, workdir, workspaceDir, promptsDir, attempt, ag, proc, chunker, cancel, done)

	tee := io.TeeReader(reader, proc.Collector())
	go readOutputLoop(tee, loopID, chunker, m.broadcastTerminal)
	go m.waitForAdapter(loopID, role, lp, ag, proc, done)

	if strings.TrimSpace(proc.InitialPrompt) != "" {
		go sendPromptToTUI(done, loopID, proc.InitialPrompt, func(data []byte) error {
			return ag.SendInput(proc, data)
		})
	}

	log.Printf("Started adapter loop %s: %s (role=%s)", loopID, agentType, role)
	return nil
}

// StopLoop sends SIGTERM to the process, then SIGKILL after 5 seconds.
// Idempotent: returns nil if the loop is not found (already stopped/never started).
func (m *Manager) StopLoop(loopID, reason string) error {
	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()
	if !exists {
		return nil
	}

	lp.mu.Lock()
	if lp.stopped {
		lp.mu.Unlock()
		<-lp.Done
		return nil
	}
	lp.stopped = true
	lpAdapter := lp.adapter
	lpProcess := lp.process
	lpSession := lp.Session
	lp.mu.Unlock()

	log.Printf("Stopping loop %s: %s", loopID, reason)

	if lpAdapter != nil {
		err := lpAdapter.Kill(lpProcess)
		<-lp.Done
		return err
	}

	return m.stopRawPTY(loopID, lp, lpSession)
}

func (m *Manager) stopRawPTY(loopID string, lp *LoopProcess, sess *ptyPkg.Session) error {
	pid := sess.Pid()
	if pid > 0 {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	select {
	case <-lp.Done:
		return nil
	case <-time.After(5 * time.Second):
		log.Printf("Loop %s did not exit after SIGTERM, sending SIGKILL", loopID)
		if pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
		lp.Cancel()
		<-lp.Done
		return nil
	}
}

// RunningCount returns the number of currently running loops.
func (m *Manager) RunningCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.loops)
}

// RunningLoopIDs returns the IDs of all currently running loops.
func (m *Manager) RunningLoopIDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.loops))
	for id := range m.loops {
		ids = append(ids, id)
	}
	return ids
}

// StartOverviewLoop runs claude in pipe mode (-p) for fast headless generation.
// Output is streamed via terminal_output events and loop_exited is sent on completion.
func (m *Manager) StartOverviewLoop(ctx context.Context, loopID, task, model string) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	loopCtx, cancel := context.WithCancel(ctx)

	args := []string{"-p", "--dangerously-skip-permissions"}
	if model != "" {
		args = append(args, "--model", model)
	}

	cmd := exec.CommandContext(loopCtx, "claude", args...)
	cmd.Dir = m.repoRoot
	cmd.Stdin = strings.NewReader(task)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("pipe stdout for overview %s: %w", loopID, err)
	}

	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("start overview %s: %w", loopID, err)
	}

	done := make(chan struct{})
	chunker := m.newTerminalChunker(loopID)

	lp := &LoopProcess{
		LoopID:  loopID,
		Chunker: chunker,
		Cancel:  cancel,
		Done:    done,
		role:    "overview",
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()

	go readOutputLoop(stdout, loopID, chunker, nil)

	go func() {
		m.waitAndNotifyExit(loopID, cmd.Wait, done)
		m.mu.Lock()
		delete(m.termStream, loopID)
		m.mu.Unlock()
	}()

	log.Printf("Started overview loop %s (model=%s)", loopID, model)
	return nil
}

// SendInput writes raw bytes to the PTY stdin of a running loop.
func (m *Manager) SendInput(loopID string, data []byte) error {
	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()
	if !exists {
		return fmt.Errorf("loop %s not found", loopID)
	}

	lp.mu.Lock()
	if lp.stopped {
		lp.mu.Unlock()
		return fmt.Errorf("loop %s is stopped", loopID)
	}
	lpAdapter := lp.adapter
	lpProcess := lp.process
	lpSession := lp.Session
	lp.mu.Unlock()

	// Adapter-managed process
	if lpAdapter != nil {
		return lpAdapter.SendInput(lpProcess, data)
	}

	// Raw PTY process
	_, err := lpSession.Write(data)
	if err != nil {
		return fmt.Errorf("writing stdin to loop %s: %w", loopID, err)
	}
	return nil
}

// ResizeLoop updates PTY dimensions for a running loop.
func (m *Manager) ResizeLoop(loopID string, cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return nil
	}

	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()
	if !exists {
		return fmt.Errorf("loop %s not found", loopID)
	}

	lp.mu.Lock()
	if lp.stopped {
		lp.mu.Unlock()
		return fmt.Errorf("loop %s is stopped", loopID)
	}
	lpAdapter := lp.adapter
	lpProcess := lp.process
	lpSession := lp.Session
	lp.mu.Unlock()

	// Adapter-managed process
	if lpAdapter != nil {
		return lpAdapter.Resize(lpProcess, cols, rows)
	}

	// Raw PTY process
	if lpSession == nil {
		return fmt.Errorf("loop %s has no PTY session", loopID)
	}
	if err := lpSession.SetSize(rows, cols); err != nil {
		return fmt.Errorf("resizing loop %s: %w", loopID, err)
	}
	return nil
}
