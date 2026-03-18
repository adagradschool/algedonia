defmodule AlgedoniaWeb.LoopComponents do
  @moduledoc """
  Shared loop UI components.
  """
  use AlgedoniaWeb, :html

  @codex_models [
    %{id: "gpt-5.3-codex", label: "gpt-5.3-codex", efforts: ["low", "medium", "high", "xhigh"]},
    %{
      id: "gpt-5.3-codex-spark",
      label: "GPT-5.3-Codex-Spark",
      efforts: ["low", "medium", "high", "xhigh"]
    },
    %{id: "gpt-5.2-codex", label: "gpt-5.2-codex", efforts: ["low", "medium", "high", "xhigh"]},
    %{
      id: "gpt-5.1-codex-max",
      label: "gpt-5.1-codex-max",
      efforts: ["low", "medium", "high", "xhigh"]
    },
    %{id: "gpt-5.2", label: "gpt-5.2", efforts: ["low", "medium", "high", "xhigh"]},
    %{id: "gpt-5.1-codex-mini", label: "gpt-5.1-codex-mini", efforts: ["medium", "high"]}
  ]
  @default_model "gpt-5.3-codex"
  @default_effort "medium"

  def codex_supported_models, do: @codex_models
  def codex_default_model, do: @default_model
  def codex_default_effort, do: @default_effort

  def codex_efforts_for_model(model) do
    case Enum.find(@codex_models, &(&1.id == model)) do
      nil -> [@default_effort]
      found -> found.efforts
    end
  end

  def init_agent_ui("codex") do
    %{
      supported_models: codex_supported_models(),
      selected_model: codex_default_model(),
      selected_effort: codex_default_effort(),
      supported_efforts: codex_efforts_for_model(codex_default_model())
    }
  end

  def init_agent_ui(_agent_type) do
    %{
      supported_models: [],
      selected_model: nil,
      selected_effort: nil,
      supported_efforts: []
    }
  end

  attr :terminal_run_key, :string, required: true
  attr :loop_id, :string, required: true
  attr :terminal_ws_url, :string, default: nil
  attr :terminal_ws_token, :string, default: nil

  def claude_terminal_panel(assigns) do
    ~H"""
    <div
      id={"terminal-#{@terminal_run_key}"}
      phx-hook="XTerm"
      phx-update="ignore"
      data-loop-id={@loop_id}
      data-terminal-drop-max-bytes={terminal_image_drop_max_bytes()}
      data-terminal-ws-url={@terminal_ws_url}
      data-terminal-ws-token={@terminal_ws_token}
      class="h-full"
    >
    </div>
    """
  end

  defp terminal_image_drop_max_bytes do
    Application.get_env(:algedonia, :terminal_image_drop_max_bytes, 10 * 1024 * 1024)
  end
end
