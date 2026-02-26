package main

import (
	"encoding/json"
	"fmt"
	"os"
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

	return cmd
}

func ticketClient() (*apiclient.Client, error) {
	client, _, err := newAPIClient(ticketWorkspace)
	if err != nil {
		return nil, err
	}
	if client.Workspace == "" {
		return nil, fmt.Errorf("no workspace set — run `ag workspace use <slug>` first")
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
				fmt.Fprintf(w, "#%d\t[P%d][%s]\t%s\t%s\t%s\n",
					t.Number, t.Priority, t.Status, t.Type, assignee, t.Title)
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

			printTicketDetail(ticket)
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

// --- helpers ---

func printTicketDetail(t *apiclient.Ticket) {
	fmt.Printf("#%d %s\n", t.Number, t.Title)
	fmt.Printf("Status: %s  Type: %s  Priority: P%d\n", t.Status, t.Type, t.Priority)

	if a := deref(t.Assignee); a != "" {
		fmt.Printf("Assignee: %s\n", a)
	}
	if a := deref(t.CodingAgent); a != "" {
		fmt.Printf("Agent: %s\n", a)
	}

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
