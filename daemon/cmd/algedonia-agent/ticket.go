package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/algedonia/daemon/internal/apiclient"
	"github.com/spf13/cobra"
)

var ticketWorkspace string

func newTicketCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "ticket",
		Aliases: []string{"t"},
		Short:   "Manage tickets",
	}

	cmd.PersistentFlags().StringVar(&ticketWorkspace, "workspace", "", "Workspace slug (overrides saved workspace)")

	cmd.AddCommand(newTicketListCmd())
	cmd.AddCommand(newTicketShowCmd())
	cmd.AddCommand(newTicketCreateCmd())
	cmd.AddCommand(newTicketUpdateCmd())
	cmd.AddCommand(newTicketDeleteCmd())
	cmd.AddCommand(newTicketStartCmd())
	cmd.AddCommand(newTicketCloseCmd())
	cmd.AddCommand(newTicketCommentCmd())
	cmd.AddCommand(newTicketCommentUpdateCmd())
	cmd.AddCommand(newTicketCommentDeleteCmd())
	cmd.AddCommand(newTicketCommentsCmd())
	cmd.AddCommand(newTicketExportCmd())

	return cmd
}

func ticketClient() (*apiclient.Client, error) {
	client, _, err := newAPIClient(ticketWorkspace)
	if err != nil {
		return nil, err
	}
	if client.Workspace == "" {
		return nil, fmt.Errorf("no workspace set — use --workspace, set ALGEDONIA_WORKSPACE, or run `%s workspace use <slug>`", commandName())
	}
	return client, nil
}

// --- list ---

func newTicketListCmd() *cobra.Command {
	var status, ticketType, priority, assignee, sortBy, sortOrder string
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "list",
		Short: "List tickets",
		Long:  "List tickets with optional filters. Supports filtering by status, assignee, and sorting.",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			tickets, err := client.ListTickets(apiclient.ListTicketsOpts{
				Status:    status,
				Type:      ticketType,
				Priority:  priority,
				Assignee:  assignee,
				SortBy:    sortBy,
				SortOrder: sortOrder,
			})
			if err != nil {
				return fmt.Errorf("listing tickets: %w", err)
			}

			if jsonOutput {
				return printJSON(tickets)
			}

			if len(tickets) == 0 {
				fmt.Fprintln(os.Stderr, "No tickets found.")
				return nil
			}

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			for _, t := range tickets {
				assignee := deref(t.Assignee)
				if assignee == "" {
					assignee = "-"
				}
				blocked := ""
				if len(t.BlockedBy) > 0 && !t.Dispatchable {
					blocked = "[blocked]"
				}
				fmt.Fprintf(w, "#%d\t[P%d][%s]\t%s\t%s\t%s\t%s\n",
					t.Number, t.Priority, t.Status, t.Type, assignee, t.Title, blocked)
			}
			return w.Flush()
		},
	}

	cmd.Flags().StringVar(&status, "status", "", "Filter by status (backlog, planning, halted, in_progress, completed, archived)")
	cmd.Flags().StringVar(&ticketType, "type", "", "Filter by type (feature, bug, chore, spike)")
	cmd.Flags().StringVar(&priority, "priority", "", "Filter by priority (1-5)")
	cmd.Flags().StringVar(&assignee, "assignee", "", "Filter by assignee")
	cmd.Flags().StringVar(&sortBy, "sort-by", "", "Sort field (priority, inserted_at, updated_at, title, number)")
	cmd.Flags().StringVar(&sortOrder, "sort-order", "", "Sort direction (asc, desc)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	return cmd
}

// --- show ---

func newTicketShowCmd() *cobra.Command {
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "show <number-or-id>",
		Short: "Show ticket details",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			ticket, err := client.GetTicket(args[0])
			if err != nil {
				return fmt.Errorf("getting ticket: %w", err)
			}

			if jsonOutput {
				return printJSON(ticket)
			}

			blockerTickets := fetchBlockerTickets(client, ticket.BlockedBy)
			printTicketDetail(ticket, blockerTickets)
			return nil
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")
	return cmd
}

// --- create ---

func newTicketCreateCmd() *cobra.Command {
	var (
		title              string
		ticketType         string
		description        string
		priority           int
		assignee           string
		acceptanceCriteria string
		rubric             string
		codingAgent        string
		blockedBy          string
		jsonOutput         bool
	)

	cmd := &cobra.Command{
		Use:   "create",
		Short: "Create a new ticket",
		Long:  "Create a ticket. Prints the ticket number to stdout for composability.",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			attrs := map[string]interface{}{
				"title":    title,
				"type":     ticketType,
				"priority": priority,
			}
			if description != "" {
				attrs["description"] = description
			}
			if assignee != "" {
				attrs["assignee"] = assignee
			}
			if acceptanceCriteria != "" {
				attrs["acceptance_criteria"] = acceptanceCriteria
			}
			if rubric != "" {
				attrs["rubric"] = rubric
			}
			if codingAgent != "" {
				attrs["coding_agent"] = codingAgent
			}
			if cmd.Flags().Changed("blocked-by") {
				ids, err := resolveBlockedBy(client, blockedBy)
				if err != nil {
					return err
				}
				attrs["blocked_by"] = ids
			}

			ticket, err := client.CreateTicket(attrs)
			if err != nil {
				return fmt.Errorf("creating ticket: %w", err)
			}

			if jsonOutput {
				return printJSON(ticket)
			}

			// Print only the number for composability (like wedow/ticket)
			fmt.Println(ticket.Number)
			return nil
		},
	}

	cmd.Flags().StringVar(&title, "title", "", "Ticket title (required)")
	cmd.Flags().StringVar(&ticketType, "type", "feature", "Ticket type (feature, bug, chore, spike)")
	cmd.Flags().StringVar(&description, "description", "", "Ticket description (markdown)")
	cmd.Flags().IntVar(&priority, "priority", 3, "Priority 1-5 (1 = highest)")
	cmd.Flags().StringVar(&assignee, "assignee", "", "Assignee")
	cmd.Flags().StringVar(&acceptanceCriteria, "acceptance-criteria", "", "Acceptance criteria (markdown)")
	cmd.Flags().StringVar(&rubric, "rubric", "", "Quality rubric")
	cmd.Flags().StringVar(&codingAgent, "coding-agent", "", "Coding agent (codex, claude_code)")
	cmd.Flags().StringVar(&blockedBy, "blocked-by", "", "Comma-separated ticket numbers this ticket depends on (e.g. 12,15)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	_ = cmd.MarkFlagRequired("title")

	return cmd
}

// --- update ---

func newTicketUpdateCmd() *cobra.Command {
	var (
		title              string
		status             string
		ticketType         string
		description        string
		priority           int
		assignee           string
		acceptanceCriteria string
		rubric             string
		codingAgent        string
		blockedBy          string
		jsonOutput         bool
	)

	cmd := &cobra.Command{
		Use:   "update <number-or-id>",
		Short: "Update a ticket",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			attrs := map[string]interface{}{}
			if cmd.Flags().Changed("title") {
				attrs["title"] = title
			}
			if cmd.Flags().Changed("status") {
				attrs["status"] = status
			}
			if cmd.Flags().Changed("type") {
				attrs["type"] = ticketType
			}
			if cmd.Flags().Changed("description") {
				attrs["description"] = description
			}
			if cmd.Flags().Changed("priority") {
				attrs["priority"] = priority
			}
			if cmd.Flags().Changed("assignee") {
				attrs["assignee"] = assignee
			}
			if cmd.Flags().Changed("acceptance-criteria") {
				attrs["acceptance_criteria"] = acceptanceCriteria
			}
			if cmd.Flags().Changed("rubric") {
				attrs["rubric"] = rubric
			}
			if cmd.Flags().Changed("coding-agent") {
				attrs["coding_agent"] = codingAgent
			}
			if cmd.Flags().Changed("blocked-by") {
				ids, err := resolveBlockedBy(client, blockedBy)
				if err != nil {
					return err
				}
				attrs["blocked_by"] = ids
			}

			if len(attrs) == 0 {
				return fmt.Errorf("no fields to update — specify at least one flag")
			}

			ticket, err := client.UpdateTicket(args[0], attrs)
			if err != nil {
				return fmt.Errorf("updating ticket: %w", err)
			}

			if jsonOutput {
				return printJSON(ticket)
			}

			fmt.Printf("Updated #%d -> %s\n", ticket.Number, ticket.Status)
			return nil
		},
	}

	cmd.Flags().StringVar(&title, "title", "", "New title")
	cmd.Flags().StringVar(&status, "status", "", "New status")
	cmd.Flags().StringVar(&ticketType, "type", "", "New type")
	cmd.Flags().StringVar(&description, "description", "", "New description")
	cmd.Flags().IntVar(&priority, "priority", 0, "New priority 1-5")
	cmd.Flags().StringVar(&assignee, "assignee", "", "New assignee")
	cmd.Flags().StringVar(&acceptanceCriteria, "acceptance-criteria", "", "New acceptance criteria")
	cmd.Flags().StringVar(&rubric, "rubric", "", "New rubric")
	cmd.Flags().StringVar(&codingAgent, "coding-agent", "", "New coding agent")
	cmd.Flags().StringVar(&blockedBy, "blocked-by", "", "Comma-separated ticket numbers (e.g. 12,15); empty string clears")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	return cmd
}

// --- delete ---

func newTicketDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "delete <number-or-id>",
		Short: "Delete a ticket",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			if err := client.DeleteTicket(args[0]); err != nil {
				return fmt.Errorf("deleting ticket: %w", err)
			}

			fmt.Printf("Deleted ticket %s\n", args[0])
			return nil
		},
	}
}

// --- start (shortcut: status -> in_progress) ---

func newTicketStartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "start <number-or-id>",
		Short: "Set ticket status to in_progress",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return quickStatus(args[0], "in_progress")
		},
	}
}

// --- close (shortcut: status -> completed) ---

func newTicketCloseCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "close <number-or-id>",
		Short: "Set ticket status to completed",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return quickStatus(args[0], "completed")
		},
	}
}

func quickStatus(idOrNumber, status string) error {
	client, err := ticketClient()
	if err != nil {
		return err
	}

	ticket, err := client.UpdateTicket(idOrNumber, map[string]interface{}{"status": status})
	if err != nil {
		return fmt.Errorf("updating status: %w", err)
	}

	fmt.Printf("Updated #%d -> %s\n", ticket.Number, ticket.Status)
	return nil
}

// --- comment ---

func newTicketCommentCmd() *cobra.Command {
	var author, body, parentID string
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "comment <number-or-id>",
		Short: "Add a comment to a ticket",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			attrs := map[string]interface{}{
				"author": author,
				"body":   body,
			}
			if parentID != "" {
				attrs["parent_id"] = parentID
			}

			comment, err := client.CreateComment(args[0], attrs)
			if err != nil {
				return fmt.Errorf("creating comment: %w", err)
			}

			if jsonOutput {
				return printJSON(comment)
			}

			fmt.Println(comment.ID)
			return nil
		},
	}

	cmd.Flags().StringVar(&author, "author", "", "Comment author (required)")
	cmd.Flags().StringVar(&body, "body", "", "Comment body (required)")
	cmd.Flags().StringVar(&parentID, "reply-to", "", "Parent comment ID for threaded replies")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	_ = cmd.MarkFlagRequired("author")
	_ = cmd.MarkFlagRequired("body")

	return cmd
}

// --- comment-update ---

func newTicketCommentUpdateCmd() *cobra.Command {
	var body string
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "comment-update <number-or-id> <comment-id>",
		Short: "Update a comment on a ticket",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			attrs := map[string]interface{}{
				"body": body,
			}

			comment, err := client.UpdateComment(args[0], args[1], attrs)
			if err != nil {
				return fmt.Errorf("updating comment: %w", err)
			}

			if jsonOutput {
				return printJSON(comment)
			}

			fmt.Printf("Updated comment %s\n", comment.ID)
			return nil
		},
	}

	cmd.Flags().StringVar(&body, "body", "", "New comment body (required)")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	_ = cmd.MarkFlagRequired("body")

	return cmd
}

// --- comment-delete ---

func newTicketCommentDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "comment-delete <number-or-id> <comment-id>",
		Short: "Delete a comment from a ticket",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			if err := client.DeleteComment(args[0], args[1]); err != nil {
				return fmt.Errorf("deleting comment: %w", err)
			}

			fmt.Printf("Deleted comment %s\n", args[1])
			return nil
		},
	}
}

// --- comments (list) ---

func newTicketCommentsCmd() *cobra.Command {
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "comments <number-or-id>",
		Short: "List comments on a ticket",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			comments, err := client.ListComments(args[0])
			if err != nil {
				return fmt.Errorf("listing comments: %w", err)
			}

			if jsonOutput {
				return printJSON(comments)
			}

			if len(comments) == 0 {
				fmt.Fprintln(os.Stderr, "No comments.")
				return nil
			}

			for _, c := range comments {
				printComment(&c, 0)
			}
			return nil
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")
	return cmd
}

// --- export ---

func newTicketExportCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "export <number-or-id>",
		Short: "Export ticket as markdown",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := ticketClient()
			if err != nil {
				return err
			}

			md, err := client.ExportTicketMarkdown(args[0])
			if err != nil {
				return fmt.Errorf("exporting ticket: %w", err)
			}

			fmt.Print(md)
			return nil
		},
	}
}

// --- helpers ---

func printTicketDetail(t *apiclient.Ticket, blockerTickets map[string]*apiclient.Ticket) {
	fmt.Printf("#%d %s\n", t.Number, t.Title)
	fmt.Printf("Status: %s  Type: %s  Priority: P%d\n", t.Status, t.Type, t.Priority)

	if a := deref(t.Assignee); a != "" {
		fmt.Printf("Assignee: %s\n", a)
	}
	if a := deref(t.CodingAgent); a != "" {
		fmt.Printf("Agent: %s\n", a)
	}

	fmt.Printf("Depends On: %s\n", formatBlockers(t.BlockedBy, blockerTickets))

	fmt.Println()

	if d := deref(t.Description); d != "" {
		fmt.Println(d)
		fmt.Println()
	}

	if ac := deref(t.AcceptanceCriteria); ac != "" {
		fmt.Println("## Acceptance Criteria")
		fmt.Println(ac)
		fmt.Println()
	}

	if r := deref(t.Rubric); r != "" {
		fmt.Println("## Rubric")
		fmt.Println(r)
		fmt.Println()
	}

	fmt.Printf("Created: %s  Updated: %s\n", t.InsertedAt, t.UpdatedAt)
	fmt.Printf("ID: %s\n", t.ID)
}

// parseBlockedByNumbers parses a comma-separated string of ticket numbers.
func parseBlockedByNumbers(raw string) ([]int, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	parts := strings.Split(raw, ",")
	numbers := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, fmt.Errorf("invalid ticket number %q: %w", p, err)
		}
		numbers = append(numbers, n)
	}

	return numbers, nil
}

// resolveBlockedBy parses a comma-separated list of ticket numbers and resolves
// them to UUIDs by fetching the workspace ticket list.
func resolveBlockedBy(client *apiclient.Client, raw string) ([]string, error) {
	numbers, err := parseBlockedByNumbers(raw)
	if err != nil {
		return nil, err
	}

	if len(numbers) == 0 {
		return []string{}, nil
	}

	tickets, err := client.ListTickets(apiclient.ListTicketsOpts{})
	if err != nil {
		return nil, fmt.Errorf("fetching tickets for number resolution: %w", err)
	}

	byNumber := make(map[int]string, len(tickets))
	for _, t := range tickets {
		byNumber[t.Number] = t.ID
	}

	ids := make([]string, 0, len(numbers))
	for _, n := range numbers {
		id, ok := byNumber[n]
		if !ok {
			return nil, fmt.Errorf("ticket #%d not found in workspace", n)
		}
		ids = append(ids, id)
	}

	return ids, nil
}

// formatBlockers renders blocker ticket IDs as "#<number> <title>" using the
// provided lookup map. Returns "None" when there are no blockers.
func formatBlockers(blockedBy []string, tickets map[string]*apiclient.Ticket) string {
	if len(blockedBy) == 0 {
		return "None"
	}

	parts := make([]string, 0, len(blockedBy))
	for _, id := range blockedBy {
		if t, ok := tickets[id]; ok {
			parts = append(parts, fmt.Sprintf("#%d %s", t.Number, t.Title))
		} else {
			parts = append(parts, id)
		}
	}

	return strings.Join(parts, ", ")
}

// fetchBlockerTickets fetches all workspace tickets and builds a lookup map
// for the given blocker IDs.
func fetchBlockerTickets(client *apiclient.Client, blockerIDs []string) map[string]*apiclient.Ticket {
	if len(blockerIDs) == 0 {
		return nil
	}

	tickets, err := client.ListTickets(apiclient.ListTicketsOpts{})
	if err != nil {
		return nil
	}

	wanted := make(map[string]bool, len(blockerIDs))
	for _, id := range blockerIDs {
		wanted[id] = true
	}

	result := make(map[string]*apiclient.Ticket, len(blockerIDs))
	for i := range tickets {
		if wanted[tickets[i].ID] {
			result[tickets[i].ID] = &tickets[i]
		}
	}
	return result
}

func printComment(c *apiclient.Comment, indent int) {
	prefix := strings.Repeat("  ", indent)
	fmt.Printf("%s[%s] %s:\n", prefix, c.InsertedAt, c.Author)
	for _, line := range strings.Split(c.Body, "\n") {
		fmt.Printf("%s  %s\n", prefix, line)
	}
	fmt.Println()

	for _, reply := range c.Replies {
		printComment(&reply, indent+1)
	}
}

func printJSON(v interface{}) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
