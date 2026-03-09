package adapter

import (
	"os"
	"time"
)

type waitOutcome struct {
	exitCode int
	fromHook bool
	err      error
}

// WaitWithCompletionMarker waits for process exit or a completion marker file,
// whichever comes first. If the marker wins, the process is killed. The marker
// file contents are appended to the collector if present.
func WaitWithCompletionMarker(proc *Process, waitProcessFn func() (int, error)) (*ExitResult, error) {
	outcomeCh := make(chan waitOutcome, 2)

	go func() {
		exitCode, err := waitProcessFn()
		outcomeCh <- waitOutcome{exitCode: exitCode, err: err}
	}()

	if proc.completionMarker != "" {
		go pollCompletionMarker(proc.completionMarker, outcomeCh)
	}

	outcome := <-outcomeCh
	if !outcome.fromHook && proc.completionMarker != "" {
		if _, err := os.Stat(proc.completionMarker); err == nil {
			outcome.fromHook = true
			outcome.exitCode = 0
		}
	}

	if outcome.fromHook {
		_ = killProcess(proc.session, 2*time.Second)
	}
	if outcome.err != nil {
		return nil, outcome.err
	}

	if outcome.fromHook && proc.completionMarker != "" {
		if raw, err := os.ReadFile(proc.completionMarker); err == nil {
			_, _ = proc.collector.Write(raw)
			_, _ = proc.collector.Write([]byte("\n"))
		}
	}

	return &ExitResult{
		ExitCode:  outcome.exitCode,
		SessionID: proc.SessionID,
		Output:    proc.collector.Bytes(),
	}, nil
}

// WaitForExit waits only for the agent process to exit and ignores completion markers.
func WaitForExit(proc *Process) (*ExitResult, error) {
	exitCode, err := waitProcess(proc.session)
	if err != nil {
		return nil, err
	}

	return &ExitResult{
		ExitCode:  exitCode,
		SessionID: proc.SessionID,
		Output:    proc.collector.Bytes(),
	}, nil
}

// pollCompletionMarker polls for the existence of the marker file every 250ms.
func pollCompletionMarker(path string, ch chan<- waitOutcome) {
	for {
		if _, err := os.Stat(path); err == nil {
			ch <- waitOutcome{exitCode: 0, fromHook: true}
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}
