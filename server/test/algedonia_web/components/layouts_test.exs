defmodule AlgedoniaWeb.LayoutsTest do
  @moduledoc """
  Tests for sidebar navigation highlighting in layouts.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AlgedoniaWeb.Layouts

  @workspace %{slug: "acme", name: "Acme Corp"}

  describe "workspace_sidebar active highlighting" do
    test "highlights inbox when inbox_active is true" do
      html = render_sidebar(inbox_active: true)
      links = nav_links(html)

      assert links["Inbox"] =~ "bg-surface-raised"
      assert links["Inbox"] =~ "font-medium"
      assert links["Inbox"] =~ "bg-accent-indigo"
      refute links["Issues"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "highlights issues when issues_active is true" do
      html = render_sidebar(issues_active: true)
      links = nav_links(html)

      assert links["Issues"] =~ "bg-surface-raised"
      assert links["Issues"] =~ "font-medium"
      assert links["Issues"] =~ "bg-accent-indigo"
      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "highlights monitor when monitor_active is true" do
      html = render_sidebar(monitor_active: true)
      links = nav_links(html)

      assert links["Monitor"] =~ "bg-surface-raised"
      assert links["Monitor"] =~ "font-medium"
      assert links["Monitor"] =~ "bg-accent-indigo"
      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Issues"] =~ "bg-surface-raised"
    end

    test "no items highlighted when all inactive" do
      html = render_sidebar([])
      links = nav_links(html)

      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Issues"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "active link includes indicator animation" do
      html = render_sidebar(issues_active: true)
      links = nav_links(html)

      assert links["Issues"] =~ "indicator-in"
      refute links["Inbox"] =~ "indicator-in"
    end

    test "inactive links have muted text styling" do
      html = render_sidebar(inbox_active: true)
      links = nav_links(html)

      assert links["Issues"] =~ "text-fg-muted"
      assert links["Monitor"] =~ "text-fg-muted"
      refute links["Inbox"] =~ "text-fg-muted"
    end

    test "renders daemon badge on avatar with online status color" do
      html =
        render_sidebar(
          current_user: %{name: "Ada", github_username: "ada", avatar_url: nil},
          workspace_daemon_status: :online
        )

      assert html =~ ~s(data-testid="workspace-daemon-badge")
      assert html =~ ~s(data-state="online")
      assert html =~ "bg-status-green"
    end

    test "renders daemon badge with unhealthy and offline colors" do
      unhealthy_html =
        render_sidebar(
          current_user: %{name: "Ada", github_username: "ada", avatar_url: nil},
          workspace_daemon_status: :unhealthy
        )

      assert unhealthy_html =~ ~s(data-state="unhealthy")
      assert unhealthy_html =~ "bg-status-yellow"

      offline_html =
        render_sidebar(
          current_user: %{name: "Ada", github_username: "ada", avatar_url: nil},
          workspace_daemon_status: :offline
        )

      assert offline_html =~ ~s(data-state="offline")
      assert offline_html =~ "bg-fg-muted"
    end
  end

  describe "nav_active? integration via app component" do
    test "app layout renders resizable/collapsible sidebar shell" do
      html = render_app([])

      assert html =~ ~s(id="workspace-layout")
      assert html =~ ~s(phx-hook="SidebarPanel")
      assert html =~ ~s(data-storage-key="left-sidebar-width")
      assert html =~ ~s(data-sidebar-handle)
      assert html =~ ~s(data-sidebar-toggle)
      assert html =~ ~s(data-collapsed-width="52")
    end

    test "nav_section :issues highlights Issues tab" do
      html = render_app(nav_section: :issues)
      links = nav_links(html)

      assert links["Issues"] =~ "bg-surface-raised"
      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "nav_section :monitor highlights Monitor tab" do
      html = render_app(nav_section: :monitor)
      links = nav_links(html)

      assert links["Monitor"] =~ "bg-surface-raised"
      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Issues"] =~ "bg-surface-raised"
    end

    test "nav_section :inbox highlights Inbox tab" do
      html = render_app(nav_section: :inbox)
      links = nav_links(html)

      assert links["Inbox"] =~ "bg-surface-raised"
      refute links["Issues"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "falls back to current_path when nav_section is nil" do
      html = render_app(current_path: "/w/acme/tickets")
      links = nav_links(html)

      assert links["Issues"] =~ "bg-surface-raised"
      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end

    test "nav_section activates its tab even when current_path differs" do
      html = render_app(nav_section: :monitor, current_path: "/w/acme/tickets")
      links = nav_links(html)

      # Monitor is active via nav_section
      assert links["Monitor"] =~ "bg-surface-raised"
      # Issues is also active via current_path fallback (expected)
      assert links["Issues"] =~ "bg-surface-raised"
    end

    test "no highlights when both nav_section and current_path are nil" do
      html = render_app([])
      links = nav_links(html)

      refute links["Inbox"] =~ "bg-surface-raised"
      refute links["Issues"] =~ "bg-surface-raised"
      refute links["Monitor"] =~ "bg-surface-raised"
    end
  end

  describe "active_path?/2" do
    test "returns false for nil current_path" do
      refute Layouts.active_path?(nil, "/tickets")
    end

    test "matches bare root path" do
      assert Layouts.active_path?("/", "/")
    end

    test "matches workspace root for home" do
      assert Layouts.active_path?("/w/acme", "/")
      assert Layouts.active_path?("/w/acme/", "/")
    end

    test "does not match workspace sub-path for home" do
      refute Layouts.active_path?("/w/acme/tickets", "/")
    end

    test "matches bare tickets path" do
      assert Layouts.active_path?("/tickets", "/tickets")
    end

    test "matches workspace-scoped tickets path" do
      assert Layouts.active_path?("/w/acme/tickets", "/tickets")
      assert Layouts.active_path?("/w/acme/tickets/123", "/tickets")
    end

    test "matches workspace-scoped monitor path" do
      assert Layouts.active_path?("/w/acme/monitor", "/monitor")
    end

    test "does not match unrelated path" do
      refute Layouts.active_path?("/w/acme/unknown", "/tickets")
      refute Layouts.active_path?("/w/acme/unknown", "/monitor")
    end

    test "does not match partial path overlap" do
      refute Layouts.active_path?("/w/acme/tickets-other", "/tickets-archived")
    end
  end

  # -- Helpers --

  defp render_app(opts) do
    assigns = %{
      flash: %{},
      current_scope: nil,
      current_workspace: @workspace,
      current_user: nil,
      workspace_daemon_status: Keyword.get(opts, :workspace_daemon_status, :offline),
      nav_section: Keyword.get(opts, :nav_section),
      current_path: Keyword.get(opts, :current_path),
      inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "" end}]
    }

    render_component(&Layouts.app/1, assigns)
  end

  defp render_sidebar(opts) do
    assigns = %{
      current_workspace: @workspace,
      current_user: Keyword.get(opts, :current_user, nil),
      workspace_daemon_status: Keyword.get(opts, :workspace_daemon_status, :offline),
      inbox_active: Keyword.get(opts, :inbox_active, false),
      issues_active: Keyword.get(opts, :issues_active, false),
      monitor_active: Keyword.get(opts, :monitor_active, false),
      inner_block: []
    }

    render_component(&Layouts.workspace_sidebar/1, assigns)
  end

  # Parse the <nav> section and return a map of %{"Label" => "<a ...>...</a>"}
  defp nav_links(html) do
    # Extract the <nav> block
    [nav_block] = Regex.run(~r/<nav[^>]*>.*?<\/nav>/s, html)

    # Split into individual <a>...</a> segments
    Regex.scan(~r/<a\s[^>]*>.*?<\/a>/s, nav_block)
    |> Enum.map(fn [link_html] ->
      # Extract the label text from <span>Label</span>
      [_, label] = Regex.run(~r/<span[^>]*>([^<]+)<\/span>\s*\n<\/a>/s, link_html)
      {String.trim(label), link_html}
    end)
    |> Map.new()
  end
end
