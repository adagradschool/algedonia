// Package apiclient provides an HTTP client for the Algedonia server REST API.
package apiclient

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Client communicates with the Algedonia server API.
type Client struct {
	BaseURL    string
	Token      string
	Workspace  string
	HTTPClient *http.Client
}

// New creates a new API client.
func New(baseURL, token, workspace string) *Client {
	return &Client{
		BaseURL:   strings.TrimRight(baseURL, "/"),
		Token:     token,
		Workspace: workspace,
		HTTPClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// Ticket represents a ticket from the API.
type Ticket struct {
	ID                 string  `json:"id"`
	Number             int     `json:"number"`
	Title              string  `json:"title"`
	Description        *string `json:"description"`
	Status             string  `json:"status"`
	Type               string  `json:"type"`
	Priority           int     `json:"priority"`
	Assignee           *string `json:"assignee"`
	CodingAgent        *string `json:"coding_agent"`
	AcceptanceCriteria *string `json:"acceptance_criteria"`
	Rubric             *string `json:"rubric"`
	InsertedAt         string  `json:"inserted_at"`
	UpdatedAt          string  `json:"updated_at"`
}

// Comment represents a comment from the API.
type Comment struct {
	ID         string    `json:"id"`
	Author     string    `json:"author"`
	Body       string    `json:"body"`
	TicketID   string    `json:"ticket_id"`
	ParentID   *string   `json:"parent_id"`
	Replies    []Comment `json:"replies,omitempty"`
	InsertedAt string    `json:"inserted_at"`
	UpdatedAt  string    `json:"updated_at"`
}

// Workspace represents a workspace from the API.
type Workspace struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Slug   string `json:"slug"`
	Prefix string `json:"prefix"`
}

// ListTicketsOpts holds optional filters for listing tickets.
type ListTicketsOpts struct {
	Status    string
	Type      string
	Priority  string
	Assignee  string
	SortBy    string
	SortOrder string
}

// ListTickets returns tickets with optional filtering.
func (c *Client) ListTickets(opts ListTicketsOpts) ([]Ticket, error) {
	params := url.Values{}
	if opts.Status != "" {
		params.Set("status", opts.Status)
	}
	if opts.Type != "" {
		params.Set("type", opts.Type)
	}
	if opts.Priority != "" {
		params.Set("priority", opts.Priority)
	}
	if opts.Assignee != "" {
		params.Set("assignee", opts.Assignee)
	}
	if opts.SortBy != "" {
		params.Set("sort_by", opts.SortBy)
	}
	if opts.SortOrder != "" {
		params.Set("sort_order", opts.SortOrder)
	}

	path := fmt.Sprintf("/api/w/%s/tickets", c.Workspace)
	if len(params) > 0 {
		path += "?" + params.Encode()
	}

	var resp struct {
		Tickets []Ticket `json:"tickets"`
	}
	if err := c.get(path, &resp); err != nil {
		return nil, err
	}
	return resp.Tickets, nil
}

// GetTicket retrieves a single ticket by ID or number.
func (c *Client) GetTicket(idOrNumber string) (*Ticket, error) {
	path := fmt.Sprintf("/api/w/%s/tickets/%s", c.Workspace, url.PathEscape(idOrNumber))

	var resp struct {
		Ticket Ticket `json:"ticket"`
	}
	if err := c.get(path, &resp); err != nil {
		return nil, err
	}
	return &resp.Ticket, nil
}

// CreateTicket creates a new ticket and returns it.
func (c *Client) CreateTicket(attrs map[string]interface{}) (*Ticket, error) {
	path := fmt.Sprintf("/api/w/%s/tickets", c.Workspace)
	body := map[string]interface{}{"ticket": attrs}

	var resp struct {
		Ticket Ticket `json:"ticket"`
	}
	if err := c.post(path, body, &resp); err != nil {
		return nil, err
	}
	return &resp.Ticket, nil
}

// UpdateTicket updates a ticket by ID or number.
func (c *Client) UpdateTicket(idOrNumber string, attrs map[string]interface{}) (*Ticket, error) {
	path := fmt.Sprintf("/api/w/%s/tickets/%s", c.Workspace, url.PathEscape(idOrNumber))
	body := map[string]interface{}{"ticket": attrs}

	var resp struct {
		Ticket Ticket `json:"ticket"`
	}
	if err := c.patch(path, body, &resp); err != nil {
		return nil, err
	}
	return &resp.Ticket, nil
}

// DeleteTicket deletes a ticket by ID or number.
func (c *Client) DeleteTicket(idOrNumber string) error {
	path := fmt.Sprintf("/api/w/%s/tickets/%s", c.Workspace, url.PathEscape(idOrNumber))
	return c.delete(path)
}

// ListComments returns comments for a ticket.
func (c *Client) ListComments(ticketIDOrNumber string) ([]Comment, error) {
	path := fmt.Sprintf("/api/w/%s/tickets/%s/comments", c.Workspace, url.PathEscape(ticketIDOrNumber))

	var resp struct {
		Comments []Comment `json:"comments"`
	}
	if err := c.get(path, &resp); err != nil {
		return nil, err
	}
	return resp.Comments, nil
}

// CreateComment adds a comment to a ticket.
func (c *Client) CreateComment(ticketIDOrNumber string, attrs map[string]interface{}) (*Comment, error) {
	path := fmt.Sprintf("/api/w/%s/tickets/%s/comments", c.Workspace, url.PathEscape(ticketIDOrNumber))
	body := map[string]interface{}{"comment": attrs}

	var resp struct {
		Comment Comment `json:"comment"`
	}
	if err := c.post(path, body, &resp); err != nil {
		return nil, err
	}
	return &resp.Comment, nil
}

// UpdateComment updates a comment's body.
func (c *Client) UpdateComment(ticketIDOrNumber, commentID string, attrs map[string]interface{}) (*Comment, error) {
	path := fmt.Sprintf("/api/w/%s/tickets/%s/comments/%s",
		c.Workspace, url.PathEscape(ticketIDOrNumber), url.PathEscape(commentID))
	body := map[string]interface{}{"comment": attrs}

	var resp struct {
		Comment Comment `json:"comment"`
	}
	if err := c.patch(path, body, &resp); err != nil {
		return nil, err
	}
	return &resp.Comment, nil
}

// DeleteComment removes a comment.
func (c *Client) DeleteComment(ticketIDOrNumber, commentID string) error {
	path := fmt.Sprintf("/api/w/%s/tickets/%s/comments/%s",
		c.Workspace, url.PathEscape(ticketIDOrNumber), url.PathEscape(commentID))
	return c.delete(path)
}

// ListWorkspaces returns all workspaces the user has access to.
func (c *Client) ListWorkspaces() ([]Workspace, error) {
	var resp struct {
		Workspaces []Workspace `json:"workspaces"`
	}
	if err := c.get("/api/workspaces", &resp); err != nil {
		return nil, err
	}
	return resp.Workspaces, nil
}

func (c *Client) get(path string, out interface{}) error {
	return c.do("GET", path, nil, out)
}

func (c *Client) post(path string, body interface{}, out interface{}) error {
	return c.do("POST", path, body, out)
}

func (c *Client) patch(path string, body interface{}, out interface{}) error {
	return c.do("PATCH", path, body, out)
}

func (c *Client) delete(path string) error {
	return c.do("DELETE", path, nil, nil)
}

// APIError represents a non-2xx response from the server.
type APIError struct {
	StatusCode int
	Body       string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("api error (status %d): %s", e.StatusCode, e.Body)
}

func (c *Client) do(method, path string, body interface{}, out interface{}) error {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshaling request: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.BaseURL+path, bodyReader)
	if err != nil {
		return fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("sending request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode >= 400 {
		return &APIError{StatusCode: resp.StatusCode, Body: string(respBody)}
	}

	if out != nil && len(respBody) > 0 {
		if err := json.Unmarshal(respBody, out); err != nil {
			return fmt.Errorf("parsing response: %w", err)
		}
	}

	return nil
}
