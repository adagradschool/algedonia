package terminalws

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type verifyRequest struct {
	Token  string `json:"token"`
	LoopID string `json:"loop_id"`
}

// APITokenVerifier validates terminal tokens by calling the Phoenix API.
type APITokenVerifier struct {
	endpointURL string
	authToken   string
	httpClient  *http.Client
}

func NewAPITokenVerifier(endpointURL, authToken string) *APITokenVerifier {
	return &APITokenVerifier{
		endpointURL: strings.TrimSpace(endpointURL),
		authToken:   strings.TrimSpace(authToken),
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func (v *APITokenVerifier) Verify(ctx context.Context, token, loopID string) error {
	reqBody, err := json.Marshal(verifyRequest{
		Token:  token,
		LoopID: loopID,
	})
	if err != nil {
		return fmt.Errorf("marshal verify request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.endpointURL, bytes.NewReader(reqBody))
	if err != nil {
		return fmt.Errorf("build verify request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+v.authToken)

	resp, err := v.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("verify token request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("verify token rejected: status=%d", resp.StatusCode)
	}
	return nil
}
