package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"os/exec"
	"time"
)

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

	return m.StartLoop(ctx, loopID, command, args, workdir, prompt)
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
func (m *Manager) HandleGetDiff(ctx context.Context, payload map[string]interface{}) error {
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

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
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
