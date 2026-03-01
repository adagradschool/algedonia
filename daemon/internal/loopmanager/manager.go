// Package loopmanager tracks running loop processes, owning PTY sessions and output streaming.
package loopmanager

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	ptyPkg "github.com/algedonia/daemon/internal/pty"
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
	adapter    adapter.AgentAdapter
	process    *adapter.Process
	role       string
	promptsDir string
	workdir    string
	attempt    int
}

// Manager tracks running loop processes and streams their output.
type Manager struct {
	mu         sync.Mutex
	loops      map[string]*LoopProcess
	termSubs   map[string]map[uint64]chan terminalstream.Chunk
	termStream map[string]*terminalStreamState
	nextSubID  uint64
	sendFunc   func(event string, payload map[string]interface{}) error
	adapterReg *adapter.Registry
	repoRoot   string
	replayMax  int
}

type terminalStreamState struct {
	nextSeq     uint64
	history     []terminalstream.Chunk
	historySize int
}

const (
	defaultChunkFlushInterval = 50 * time.Millisecond
	defaultChunkMaxSize       = 4096
	defaultReplayMaxBytes     = 8 * 1024 * 1024
	minChunkFlushMS           = 1
	minChunkMaxBytes          = 256
	minReplayMaxBytes         = 64 * 1024
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

func (m *Manager) sendEvent(event string, payload map[string]interface{}) {
	if err := m.sendFunc(event, payload); err != nil {
		loopID, _ := payload["loop_id"].(string)
		log.Printf("Failed to send %s event for loop %s: %v", event, loopID, err)
	}
}

func (m *Manager) broadcastTerminal(loopID string, data []byte) {
	m.mu.Lock()

	stream, ok := m.termStream[loopID]
	if !ok {
		stream = &terminalStreamState{}
		m.termStream[loopID] = stream
	}
	stream.nextSeq++
	chunk := terminalstream.Chunk{
		Seq:  stream.nextSeq,
		Data: append([]byte(nil), data...),
	}
	stream.history = append(stream.history, chunk)
	stream.historySize += len(chunk.Data)
	for stream.historySize > m.replayMax && len(stream.history) > 0 {
		dropped := stream.history[0]
		stream.history = stream.history[1:]
		stream.historySize -= len(dropped.Data)
	}

	subs := m.termSubs[loopID]
	if len(subs) == 0 {
		m.mu.Unlock()
		return
	}
	type terminalSub struct {
		id uint64
		ch chan terminalstream.Chunk
	}
	chans := make([]terminalSub, 0, len(subs))
	for id, ch := range subs {
		chans = append(chans, terminalSub{id: id, ch: ch})
	}
	m.mu.Unlock()

	for _, sub := range chans {
		select {
		case sub.ch <- chunk:
		default:
			// Do not silently drop PTY bytes: that corrupts ANSI state and causes
			// garbled output. Disconnect the slow subscriber so it can reconnect
			// and resync from canonical scrollback.
			log.Printf("terminal subscriber overflow for loop %s (sub=%d), disconnecting", loopID, sub.id)
			m.unsubscribeTerminal(loopID, sub.id)
		}
	}
}

func (m *Manager) unsubscribeTerminal(loopID string, id uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()

	subs, ok := m.termSubs[loopID]
	if !ok {
		return
	}
	ch, ok := subs[id]
	if !ok {
		return
	}
	delete(subs, id)
	close(ch)
	if len(subs) == 0 {
		delete(m.termSubs, loopID)
	}
}

func cloneChunk(chunk terminalstream.Chunk) terminalstream.Chunk {
	cloned := terminalstream.Chunk{
		Seq:  chunk.Seq,
		Data: make([]byte, len(chunk.Data)),
	}
	copy(cloned.Data, chunk.Data)
	return cloned
}

// SubscribeTerminal streams ordered PTY output for a loop to a dedicated subscriber.
// If fromSeq > 0, replay includes buffered chunks with Seq >= fromSeq.
func (m *Manager) SubscribeTerminal(loopID string, fromSeq uint64) ([]terminalstream.Chunk, <-chan terminalstream.Chunk, func()) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.termSubs[loopID]; !ok {
		m.termSubs[loopID] = make(map[uint64]chan terminalstream.Chunk)
	}
	id := m.nextSubID
	m.nextSubID++

	ch := make(chan terminalstream.Chunk, 128)
	m.termSubs[loopID][id] = ch

	replay := make([]terminalstream.Chunk, 0)
	if fromSeq > 0 {
		if stream := m.termStream[loopID]; stream != nil {
			for _, item := range stream.history {
				if item.Seq >= fromSeq {
					replay = append(replay, cloneChunk(item))
				}
			}
		}
	}

	return replay, ch, func() {
		m.unsubscribeTerminal(loopID, id)
	}
}

func payloadStr(p map[string]interface{}, key string) string {
	s, _ := p[key].(string)
	return s
}

func chunkFlushIntervalFromEnv(getenv func(string) string) time.Duration {
	raw := strings.TrimSpace(getenv("ALGEDONIA_CHUNK_FLUSH_MS"))
	if raw == "" {
		return defaultChunkFlushInterval
	}

	ms, err := strconv.Atoi(raw)
	if err != nil || ms < minChunkFlushMS {
		log.Printf(
			"Invalid ALGEDONIA_CHUNK_FLUSH_MS=%q, using default %dms",
			raw,
			defaultChunkFlushInterval/time.Millisecond,
		)
		return defaultChunkFlushInterval
	}

	return time.Duration(ms) * time.Millisecond
}

func chunkMaxSizeFromEnv(getenv func(string) string) int {
	raw := strings.TrimSpace(getenv("ALGEDONIA_CHUNK_MAX_BYTES"))
	if raw == "" {
		return defaultChunkMaxSize
	}

	size, err := strconv.Atoi(raw)
	if err != nil || size < minChunkMaxBytes {
		log.Printf(
			"Invalid ALGEDONIA_CHUNK_MAX_BYTES=%q, using default %d",
			raw,
			defaultChunkMaxSize,
		)
		return defaultChunkMaxSize
	}

	return size
}

func replayMaxBytesFromEnv(getenv func(string) string) int {
	raw := strings.TrimSpace(getenv("ALGEDONIA_TERMINAL_REPLAY_BYTES"))
	if raw == "" {
		return defaultReplayMaxBytes
	}

	size, err := strconv.Atoi(raw)
	if err != nil || size < minReplayMaxBytes {
		log.Printf(
			"Invalid ALGEDONIA_TERMINAL_REPLAY_BYTES=%q, using default %d",
			raw,
			defaultReplayMaxBytes,
		)
		return defaultReplayMaxBytes
	}

	return size
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

// sendPromptToTUI waits for warmup, types prompt text character-by-character
// (simulating keyboard input), then presses Enter.
//
// Ink-based TUI agents (Codex, Claude Code) detect rapid bulk writes as paste
// bursts and treat CR as a newline within the input rather than as submit.
// Typing one character at a time with inter-character delays avoids paste
// detection and ensures Enter is interpreted as submit.
func sendPromptToTUI(
	done <-chan struct{},
	loopID, prompt string,
	writeFn func([]byte) error,
) {
	const (
		warmup      = 1500 * time.Millisecond
		charDelay   = 5 * time.Millisecond
		settleDelay = 300 * time.Millisecond
	)

	if !waitOrDone(done, warmup) {
		return
	}

	// Type each character individually to avoid paste-burst detection.
	for _, ch := range []byte(prompt) {
		select {
		case <-done:
			return
		default:
		}
		if err := writeFn([]byte{ch}); err != nil {
			log.Printf("Failed to send prompt char to loop %s: %v", loopID, err)
			return
		}
		if !waitOrDone(done, charDelay) {
			return
		}
	}

	// Let the TUI settle after the last character.
	if !waitOrDone(done, settleDelay) {
		return
	}

	if err := writeFn([]byte("\r")); err != nil {
		log.Printf("Failed to send Enter to loop %s: %v", loopID, err)
		return
	}

	log.Printf("Prompt submitted for loop %s (%d bytes)", loopID, len(prompt))
}

// waitOrDone sleeps for d but returns early if done is closed.
// Returns true if the duration elapsed, false if done was signalled.
func waitOrDone(done <-chan struct{}, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-done:
		return false
	case <-t.C:
		return true
	}
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

	// Output reader goroutine
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := sess.Reader().Read(buf)
			if n > 0 {
				m.broadcastTerminal(loopID, buf[:n])
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
	}()

	// Wait goroutine — detects process exit
	go func() {
		defer close(done)
		waitErr := sess.Wait()
		sess.Close()

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
	}()

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
func (m *Manager) StartLoopWithAdapter(ctx context.Context, loopID, agentType, role, workdir, taskDesc, model, effort string, attempt int) error {
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

	// Load prompt for the role
	promptsDir := filepath.Join(workdir, ".algedonia", "prompts")
	systemPrompt, err := adapter.LoadPrompt(promptsDir, role)
	if err != nil {
		log.Printf("Warning: could not load prompt for role %q: %v", role, err)
		systemPrompt = ""
	}

	// Construct task string
	task := taskDesc
	if systemPrompt != "" {
		task = systemPrompt + "\n\n---\n\n" + taskDesc
	}
	if role == "decompose" {
		task += "\n\nIMPORTANT: Output your DAG as JSON between these exact delimiters:\n---ALGEDONIA_DAG_BEGIN---\n<your JSON here>\n---ALGEDONIA_DAG_END---"
	}

	proc, err := ag.Start(workdir, task, map[string]string{
		"loop_id": loopID,
		"role":    role,
		"workdir": workdir,
		"model":   strings.TrimSpace(model),
		"effort":  strings.TrimSpace(effort),
	})
	if err != nil {
		return fmt.Errorf("starting adapter for loop %s: %w", loopID, err)
	}

	reader, _, err := ag.AttachPTY(proc)
	if err != nil {
		ag.Kill(proc)
		return fmt.Errorf("attaching pty for loop %s: %w", loopID, err)
	}

	_, cancel := context.WithCancel(ctx)
	done := make(chan struct{})

	chunker := m.newTerminalChunker(loopID)

	lp := &LoopProcess{
		LoopID:     loopID,
		Chunker:    chunker,
		Cancel:     cancel,
		Done:       done,
		adapter:    ag,
		process:    proc,
		role:       role,
		promptsDir: promptsDir,
		workdir:    workdir,
		attempt:    attempt,
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()

	// Output reader goroutine — dual-write to chunker and output collector
	go func() {
		// Use TeeReader to write to both the chunker (streaming) and the collector (post-exit parsing)
		tee := io.TeeReader(reader, proc.Collector())
		buf := make([]byte, 4096)
		for {
			n, err := tee.Read(buf)
			if n > 0 {
				m.broadcastTerminal(loopID, buf[:n])
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
	}()

	// Wait goroutine — handles result based on role
	go func() {
		defer close(done)
		defer func() {
			lp.mu.Lock()
			lp.stopped = true
			lpAdapter := lp.adapter
			lpProcess := lp.process
			lp.mu.Unlock()

			if err := closeAdapterProcess(lpAdapter, lpProcess); err != nil {
				log.Printf("Failed to close adapter process for loop %s: %v", loopID, err)
			}
			m.mu.Lock()
			delete(m.loops, loopID)
			delete(m.termStream, loopID)
			m.mu.Unlock()
		}()

		result, waitErr := ag.Wait(proc)

		sessionID := ag.SessionID(proc)

		if waitErr != nil {
			m.sendEvent("error", map[string]interface{}{
				"loop_id":     loopID,
				"message":     fmt.Sprintf("agent wait error: %v", waitErr),
				"recoverable": true,
			})
			return
		}

		switch role {
		case "decompose":
			dag, parseErr := adapter.ParseDAGOutput(result.Output)
			if parseErr != nil {
				m.sendEvent("error", map[string]interface{}{
					"loop_id":     loopID,
					"message":     fmt.Sprintf("decompose output parse error: %v", parseErr),
					"recoverable": true,
				})
			} else {
				m.sendEvent("loop_result", map[string]interface{}{
					"loop_id":    loopID,
					"verdict":    "pass",
					"dag":        dag,
					"session_id": sessionID,
				})
			}
		default:
			if result.ExitCode != 0 {
				m.sendEvent("error", map[string]interface{}{
					"loop_id":     loopID,
					"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
					"recoverable": true,
				})
			} else {
				attemptPayload := map[string]interface{}{
					"loop_id":    loopID,
					"exit_code":  result.ExitCode,
					"session_id": sessionID,
				}

				if role == "checker" {
					lp.mu.Lock()
					lpAttempt := lp.attempt
					lp.mu.Unlock()

					expectedJSONPath, expectedFeedbackPath :=
						expectedCheckerHandoffPaths(loopID, lpAttempt)
					attemptPayload["expected_handoff_json_path"] = expectedJSONPath
					attemptPayload["expected_handoff_feedback_path"] = expectedFeedbackPath
					attemptPayload["attempt"] = lpAttempt

					verdict, feedbackPath, feedback, parseErr :=
						loadCheckerHandoff(loopID, lpAttempt)
					if parseErr != nil {
						m.sendEvent("error", map[string]interface{}{
							"loop_id":     loopID,
							"message":     fmt.Sprintf("checker handoff parse error: %v", parseErr),
							"recoverable": true,
						})
						attemptPayload["handoff_valid"] = false
						attemptPayload["handoff_error"] = parseErr.Error()
						attemptPayload["verdict"] = "fail"
						attemptPayload["feedback"] =
							"Checker did not produce required handoff JSON/markdown files."
					} else {
						attemptPayload["handoff_valid"] = true
						attemptPayload["verdict"] = verdict
						attemptPayload["feedback_path"] = feedbackPath
						attemptPayload["feedback"] = feedback
					}
				}

				m.sendEvent("attempt_complete", attemptPayload)
			}
		}

	}()

	// If the agent is a TUI (no -p flag mode), type the prompt
	if strings.TrimSpace(proc.InitialPrompt) != "" {
		writeFn := func(data []byte) error {
			return ag.SendInput(proc, data)
		}
		go sendPromptToTUI(done, loopID, proc.InitialPrompt, writeFn)
	}

	log.Printf("Started adapter loop %s: %s (role=%s)", loopID, agentType, role)
	return nil
}

type checkerHandoff struct {
	VERDICT  string `json:"VERDICT"`
	FEEDBACK string `json:"FEEDBACK"`
}

func globalAlgedoniaDir() string {
	if custom := strings.TrimSpace(os.Getenv("ALGEDONIA_HOME")); custom != "" {
		return filepath.Clean(custom)
	}
	home, err := os.UserHomeDir()
	if err == nil && strings.TrimSpace(home) != "" {
		return filepath.Join(home, ".algedonia")
	}
	return filepath.Clean(".algedonia")
}

func checkerHandoffSuffix(loopID string, attempt int) string {
	return filepath.ToSlash(filepath.Join(".algedonia", "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt), "checker_feedback.md"))
}

func expectedCheckerHandoffPaths(loopID string, attempt int) (string, string) {
	base := filepath.Join(globalAlgedoniaDir(), "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt))
	return filepath.Join(base, "checker_result.json"), filepath.Join(base, "checker_feedback.md")
}

func loadCheckerHandoff(loopID string, attempt int) (string, string, string, error) {
	handoffPath, expectedFeedbackPath := expectedCheckerHandoffPaths(loopID, attempt)
	raw, err := os.ReadFile(handoffPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read %s: %w", handoffPath, err)
	}

	var handoff checkerHandoff
	if err := json.Unmarshal(raw, &handoff); err != nil {
		return "", "", "", fmt.Errorf("decode checker handoff json: %w", err)
	}

	verdict := strings.ToLower(strings.TrimSpace(handoff.VERDICT))
	if verdict != "pass" && verdict != "fail" {
		return "", "", "", fmt.Errorf("invalid VERDICT %q", handoff.VERDICT)
	}

	feedbackPath := strings.TrimSpace(handoff.FEEDBACK)
	if feedbackPath == "" {
		return "", "", "", fmt.Errorf("missing FEEDBACK path")
	}

	absFeedbackPath := strings.TrimSpace(feedbackPath)
	if strings.HasPrefix(absFeedbackPath, "~/") {
		home, err := os.UserHomeDir()
		if err == nil && strings.TrimSpace(home) != "" {
			absFeedbackPath = filepath.Join(home, absFeedbackPath[2:])
		}
	}
	if !filepath.IsAbs(absFeedbackPath) {
		absFeedbackPath = filepath.Join(globalAlgedoniaDir(), absFeedbackPath)
	}
	absFeedbackPath = filepath.Clean(absFeedbackPath)
	expectedFeedbackPath = filepath.Clean(expectedFeedbackPath)
	if absFeedbackPath != expectedFeedbackPath &&
		!strings.HasSuffix(filepath.ToSlash(absFeedbackPath), checkerHandoffSuffix(loopID, attempt)) {
		return "", "", "", fmt.Errorf("FEEDBACK path must be %s", filepath.Clean(expectedFeedbackPath))
	}

	markdown, err := os.ReadFile(absFeedbackPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read FEEDBACK markdown %s: %w", absFeedbackPath, err)
	}

	feedback := strings.TrimSpace(string(markdown))
	if feedback == "" {
		return "", "", "", fmt.Errorf("FEEDBACK markdown is empty at %s", absFeedbackPath)
	}

	return verdict, filepath.Clean(absFeedbackPath), feedback, nil
}

// StopLoop sends SIGTERM to the process, then SIGKILL after 5 seconds.
func (m *Manager) StopLoop(loopID, reason string) error {
	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()
	if !exists {
		return fmt.Errorf("loop %s not found", loopID)
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

	// Read stdout and stream to chunker
	go func() {
		buf := make([]byte, 4096)
		for {
			n, readErr := stdout.Read(buf)
			if n > 0 {
				chunker.Write(buf[:n])
			}
			if readErr != nil {
				break
			}
		}
		chunker.Close()
	}()

	// Wait for process exit and notify server
	go func() {
		defer close(done)
		waitErr := cmd.Wait()

		exitCode := 0
		if waitErr != nil {
			if exitErr, ok := waitErr.(*exec.ExitError); ok {
				exitCode = exitErr.ExitCode()
			} else {
				exitCode = -1
			}
		}

		m.sendEvent("loop_exited", map[string]interface{}{
			"loop_id":   loopID,
			"exit_code": exitCode,
		})

		m.mu.Lock()
		delete(m.loops, loopID)
		delete(m.termStream, loopID)
		m.mu.Unlock()
	}()

	log.Printf("Started overview loop %s (model=%s)", loopID, model)
	return nil
}

// HandleStartLoop is a command handler for "start_loop" events from the server.
func (m *Manager) HandleStartLoop(ctx context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in start_loop payload")
	}

	// Overview role uses headless pipe mode for fast generation
	role := payloadStr(payload, "role")
	if role == "overview" {
		return m.StartOverviewLoop(ctx, loopID, payloadStr(payload, "task"), payloadStr(payload, "model"))
	}

	// If a role is specified, route through adapter path
	if role != "" {
		agentType := payloadStr(payload, "agent_type")
		if agentType == "" {
			agentType = defaultCodingAgent()
		}
		attempt := parseAttempt(payload["attempt"])
		workdir := payloadStr(payload, "workdir")
		if workdir == "" {
			workdir = m.repoRoot
		}
		return m.StartLoopWithAdapter(ctx, loopID, agentType, role, workdir,
			payloadStr(payload, "task"), payloadStr(payload, "model"), payloadStr(payload, "effort"), attempt)
	}

	// Legacy raw-process path
	command := payloadStr(payload, "command")
	if command == "" {
		command = "claude"
	}

	var args []string
	if rawArgs, ok := payload["args"].([]interface{}); ok {
		for _, a := range rawArgs {
			if s, ok := a.(string); ok {
				args = append(args, s)
			}
		}
	}
	if len(args) == 0 && command == "claude" {
		args = []string{"--dangerously-skip-permissions"}
	}

	workdir := payloadStr(payload, "workdir")

	prompt := payloadStr(payload, "prompt")
	if prompt == "" && command == "claude" {
		prompt = "Say hello and describe what you see in this repo"
	}

	return m.StartLoop(ctx, loopID, command, args, workdir, prompt)
}

func defaultCodingAgent() string {
	switch strings.TrimSpace(strings.ToLower(os.Getenv("ALGEDONIA_DEFAULT_CODING_AGENT"))) {
	case "claude_code":
		return "claude_code"
	case "codex":
		return "codex"
	default:
		return "claude_code"
	}
}

func parseAttempt(raw interface{}) int {
	switch v := raw.(type) {
	case int:
		return v
	case int32:
		return int(v)
	case int64:
		return int(v)
	case float64:
		return int(v)
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(v))
		if err == nil {
			return parsed
		}
	}
	return 1
}

func closeAdapterProcess(ag adapter.AgentAdapter, proc *adapter.Process) error {
	if ag == nil || proc == nil {
		return nil
	}
	// Adapter process cleanup hook. TUI adapters exit with Wait() and need no extra cleanup.
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

// HandleStdinInput is a command handler for "stdin_input" events from the server.
func (m *Manager) HandleStdinInput(_ context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stdin_input payload")
	}
	dataStr := payloadStr(payload, "data")
	if dataStr == "" {
		return nil
	}
	data, err := base64.StdEncoding.DecodeString(dataStr)
	if err != nil {
		return fmt.Errorf("decoding stdin_input base64: %w", err)
	}
	return m.SendInput(loopID, data)
}

// HandleStopLoop is a command handler for "stop_loop" events from the server.
func (m *Manager) HandleStopLoop(_ context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stop_loop payload")
	}

	reason := payloadStr(payload, "reason")
	if reason == "" {
		reason = "server requested stop"
	}

	return m.StopLoop(loopID, reason)
}

// HandleGetDiff runs `git diff HEAD` in the loop's working directory and sends the
// result back to the server as a diff_result event.
func (m *Manager) HandleGetDiff(_ context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in get_diff payload")
	}

	workdir := m.repoRoot
	m.mu.Lock()
	if lp, ok := m.loops[loopID]; ok && lp.workdir != "" {
		workdir = lp.workdir
	}
	m.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", "diff", "HEAD")
	cmd.Dir = workdir
	out, err := cmd.Output()

	result := map[string]interface{}{
		"loop_id": loopID,
	}

	if err != nil {
		result["error"] = fmt.Sprintf("git diff failed: %v", err)
		result["diff"] = ""
	} else {
		result["diff"] = string(out)
	}

	m.sendEvent("diff_result", result)
	return nil
}
