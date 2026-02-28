defmodule AlgedoniaWeb.LoopLive.DiffTab do
  @moduledoc """
  Diff tab logic for the loop inspector. Handles polling, debouncing,
  and inline review comments. Used as a helper by LoopLive.Show.
  """

  import Phoenix.Component, only: [assign: 3]
  import AlgedoniaWeb.Helpers, only: [resolve_daemon: 1]

  alias Algedonia.{DiffParser, InlineReviews}
  alias AlgedoniaWeb.DaemonChannel

  @poll_interval 5_000
  @debounce_delay 500

  @doc """
  Assigns default diff-related state to the socket.
  """
  def init_assigns(socket) do
    socket
    |> assign(:diff_content, nil)
    |> assign(:diff_loading, false)
    |> assign(:diff_error, nil)
    |> assign(:inline_reviews, [])
    |> assign(:diff_poll_timer, nil)
    |> assign(:diff_request_pending, false)
    |> assign(:diff_debounce_timer, nil)
    |> assign(:inline_comment_form, nil)
  end

  @doc """
  Handles switching to the diff tab. Starts debounced fetch.
  """
  def on_tab_enter(socket) do
    socket = cancel_diff_timers(socket)
    timer = Process.send_after(self(), :diff_debounce_fire, @debounce_delay)

    socket
    |> assign(:active_tab, "diff")
    |> assign(:diff_loading, true)
    |> assign(:diff_debounce_timer, timer)
    |> load_inline_reviews()
  end

  @doc """
  Handles switching away from the diff tab. Cancels all timers.
  """
  def on_tab_leave(socket) do
    cancel_diff_timers(socket)
  end

  @doc """
  Handles the debounce timer firing. Fetches diff if possible.
  """
  def handle_debounce_fire(socket) do
    socket = assign(socket, :diff_debounce_timer, nil)
    fetch_diff(socket)
  end

  @doc """
  Handles a poll tick. Fetches diff if tab is still active and maker is running.
  """
  def handle_poll_tick(socket) do
    socket = assign(socket, :diff_poll_timer, nil)

    if socket.assigns.active_tab == "diff" && maker_running?(socket) do
      fetch_diff(socket)
    else
      socket
    end
  end

  @doc """
  Handles diff result from daemon.
  """
  def handle_diff_result(socket, diff_text, error) do
    socket =
      socket
      |> assign(:diff_request_pending, false)
      |> assign(:diff_loading, false)

    socket =
      if error do
        assign(socket, :diff_error, error)
      else
        socket
        |> assign(:diff_content, diff_text)
        |> assign(:diff_error, nil)
      end

    maybe_schedule_poll(socket)
  end

  @doc """
  Handles manual refresh. Immediate fetch, resets poll timer.
  """
  def handle_refresh(socket) do
    socket = cancel_poll_timer(socket)
    fetch_diff(socket)
  end

  @doc """
  Creates an inline review comment from the form submission.
  """
  def handle_add_inline_comment(socket, params) do
    loop_id = socket.assigns.loop_id
    diff_files = DiffParser.parse(socket.assigns.diff_content)

    hunk_context =
      DiffParser.extract_hunk_context(
        diff_files,
        params["file_path"],
        String.to_integer(params["line_number"])
      )

    attrs = %{
      loop_id: loop_id,
      author: current_author(socket),
      file_path: params["file_path"],
      line_number: String.to_integer(params["line_number"]),
      diff_hunk: hunk_context,
      body: params["body"]
    }

    case InlineReviews.create(attrs) do
      {:ok, _review} -> load_inline_reviews(socket)
      {:error, _changeset} -> socket
    end
  end

  @doc """
  Cancels all diff-related timers. Call on tab leave and terminate.
  """
  def cancel_diff_timers(socket) do
    socket
    |> cancel_poll_timer()
    |> cancel_debounce_timer()
  end

  # -- Private --

  defp fetch_diff(socket) do
    if socket.assigns.diff_request_pending do
      socket
    else
      case resolve_daemon(socket) do
        {:ok, daemon} ->
          DaemonChannel.push_get_diff(daemon.name, socket.assigns.loop_id)

          socket
          |> assign(:diff_request_pending, true)
          |> assign(:diff_loading, socket.assigns.diff_content == nil)

        {:error, _} ->
          assign(socket, :diff_loading, false)
      end
    end
  end

  defp maybe_schedule_poll(socket) do
    if socket.assigns.active_tab == "diff" && maker_running?(socket) do
      timer = Process.send_after(self(), :poll_diff, @poll_interval)
      assign(socket, :diff_poll_timer, timer)
    else
      socket
    end
  end

  defp cancel_poll_timer(socket) do
    if timer = socket.assigns[:diff_poll_timer] do
      Process.cancel_timer(timer)
    end

    assign(socket, :diff_poll_timer, nil)
  end

  defp cancel_debounce_timer(socket) do
    if timer = socket.assigns[:diff_debounce_timer] do
      Process.cancel_timer(timer)
    end

    assign(socket, :diff_debounce_timer, nil)
  end

  defp load_inline_reviews(socket) do
    reviews = InlineReviews.list_by_loop(socket.assigns.loop_id)
    assign(socket, :inline_reviews, reviews)
  end

  defp maker_running?(socket) do
    socket.assigns[:active] == true &&
      socket.assigns[:stage] == "maker"
  end

  defp current_author(socket) do
    case socket.assigns[:current_user] do
      %{github_username: username} when is_binary(username) -> username
      %{email: email} when is_binary(email) -> email
      _ -> "reviewer"
    end
  end
end
