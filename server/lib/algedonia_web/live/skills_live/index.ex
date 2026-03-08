defmodule AlgedoniaWeb.SkillsLive.Index do
  @moduledoc """
  Read-only skills catalog and skill selectors for planning/checker configuration.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.Skills

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Skills")
     |> assign(:planning_selected_skills, [])
     |> assign(:checker_selected_skills, [])
     |> load_catalog()}
  end

  @impl true
  def handle_event("retry_catalog", _params, socket) do
    {:noreply, load_catalog(socket)}
  end

  def handle_event("toggle_planning_skill", %{"skill" => skill_name}, socket) do
    {:noreply, update_selection(socket, :planning_selected_skills, skill_name)}
  end

  def handle_event("toggle_checker_skill", %{"skill" => skill_name}, socket) do
    {:noreply, update_selection(socket, :checker_selected_skills, skill_name)}
  end

  defp load_catalog(socket) do
    payload = Skills.catalog()
    entries = Map.fetch!(payload, :entries)

    selectable_skill_names =
      entries
      |> Enum.filter(&(&1.validation_status == "valid"))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    socket
    |> assign(:catalog_entries, entries)
    |> assign(:catalog_load_error, payload.load_error)
    |> assign(:catalog_selectable_names, selectable_skill_names)
    |> assign(
      :planning_selected_skills,
      Enum.filter(
        socket.assigns.planning_selected_skills,
        &MapSet.member?(selectable_skill_names, &1)
      )
    )
    |> assign(
      :checker_selected_skills,
      Enum.filter(
        socket.assigns.checker_selected_skills,
        &MapSet.member?(selectable_skill_names, &1)
      )
    )
  end

  defp update_selection(socket, key, skill_name) do
    selectable = socket.assigns.catalog_selectable_names

    if MapSet.member?(selectable, skill_name) do
      update(socket, key, &toggle_skill(&1, skill_name))
    else
      socket
    end
  end

  defp toggle_skill(selected, skill_name) when is_list(selected) do
    if skill_name in selected do
      List.delete(selected, skill_name)
    else
      selected ++ [skill_name]
    end
  end

  defp status_badge_classes("valid"),
    do: "bg-status-green/15 text-status-green border-status-green/40"

  defp status_badge_classes("invalid"),
    do: "bg-status-red/15 text-status-red border-status-red/40"

  defp status_badge_classes(_), do: "bg-fg-muted/15 text-fg-muted border-border"

  defp format_status(status) when is_binary(status), do: String.capitalize(status)

  defp selection_disabled?(entry, load_error) do
    not is_nil(load_error) or entry.validation_status != "valid"
  end

  defp selector_entry_classes(entry) do
    if entry.validation_status == "valid" do
      "rounded-md border border-border bg-surface-raised/20 p-2"
    else
      "rounded-md border border-status-red/30 bg-status-red/5 p-2"
    end
  end

  defp diagnostic_context(diagnostic) do
    [
      maybe_context("File", diagnostic.file),
      maybe_context("Field", diagnostic.field),
      maybe_context("Path", diagnostic.path),
      maybe_context("Index", diagnostic.index && Integer.to_string(diagnostic.index))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp maybe_context(_label, nil), do: nil
  defp maybe_context(_label, ""), do: nil
  defp maybe_context(label, value), do: "#{label}: #{value}"
end
