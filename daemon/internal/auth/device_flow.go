// Package auth handles GitHub device flow authentication via the server's API.
package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// DeviceCodeResponse is the server's response to a device code request.
type DeviceCodeResponse struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

// PollResponse is the server's response when polling for device auth completion.
type PollResponse struct {
	Status string `json:"status"`
	Token  string `json:"token,omitempty"`
	Reason string `json:"reason,omitempty"`
	Error  string `json:"error,omitempty"`
}

// DeviceFlow handles device code authentication with injectable dependencies.
type DeviceFlow struct {
	HTTPClient    *http.Client
	SleepFunc     func(time.Duration)
	ServerBaseURL string
}

// NewDeviceFlow creates a DeviceFlow with sensible defaults.
func NewDeviceFlow(serverBaseURL string) *DeviceFlow {
	return &DeviceFlow{
		HTTPClient:    &http.Client{Timeout: 30 * time.Second},
		SleepFunc:     time.Sleep,
		ServerBaseURL: serverBaseURL,
	}
}

// RequestDeviceCode calls the server API to initiate a GitHub device flow.
func (d *DeviceFlow) RequestDeviceCode() (*DeviceCodeResponse, error) {
	resp, err := d.HTTPClient.Post(d.ServerBaseURL+"/api/auth/device/code", "application/json", nil)
	if err != nil {
		return nil, fmt.Errorf("requesting device code: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("server returned %d: %s", resp.StatusCode, body)
	}

	var result DeviceCodeResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parsing response: %w", err)
	}
	return &result, nil
}

// PollForToken polls the server until the user completes the device flow or it expires.
func (d *DeviceFlow) PollForToken(ctx context.Context, deviceCode string, interval, expiresIn int) (string, error) {
	pollInterval := time.Duration(interval) * time.Second
	deadline := time.Now().Add(time.Duration(expiresIn) * time.Second)

	for time.Now().Before(deadline) {
		d.SleepFunc(pollInterval)

		select {
		case <-ctx.Done():
			return "", fmt.Errorf("device flow cancelled: %w", ctx.Err())
		default:
		}

		payload, err := json.Marshal(map[string]string{"device_code": deviceCode})
		if err != nil {
			return "", fmt.Errorf("marshaling poll request: %w", err)
		}

		resp, err := d.HTTPClient.Post(d.ServerBaseURL+"/api/auth/device/poll", "application/json", bytes.NewReader(payload))
		if err != nil {
			return "", fmt.Errorf("polling for token: %w", err)
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return "", fmt.Errorf("reading poll response: %w", err)
		}

		var result PollResponse
		if err := json.Unmarshal(body, &result); err != nil {
			return "", fmt.Errorf("parsing poll response: %w", err)
		}

		switch result.Status {
		case "ok":
			return result.Token, nil
		case "pending":
			if result.Reason == "slow_down" {
				pollInterval += 5 * time.Second
			}
			continue
		case "error":
			return "", fmt.Errorf("auth failed: %s", result.Error)
		default:
			if resp.StatusCode == 202 {
				continue
			}
			return "", fmt.Errorf("unexpected poll response (status %d): %s", resp.StatusCode, body)
		}
	}

	return "", fmt.Errorf("device flow expired")
}

// RequestDeviceCode calls the server API to initiate a GitHub device flow.
// Deprecated: Use DeviceFlow.RequestDeviceCode instead.
func RequestDeviceCode(serverBaseURL string) (*DeviceCodeResponse, error) {
	return NewDeviceFlow(serverBaseURL).RequestDeviceCode()
}

// PollForToken polls the server until the user completes the device flow or it expires.
// Deprecated: Use DeviceFlow.PollForToken instead.
func PollForToken(serverBaseURL, deviceCode string, interval, expiresIn int) (string, error) {
	return NewDeviceFlow(serverBaseURL).PollForToken(context.Background(), deviceCode, interval, expiresIn)
}
