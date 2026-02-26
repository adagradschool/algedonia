defmodule AlgedoniaWeb.LoopComponents do
  @moduledoc """
  Shared loop UI components.
  """
  use AlgedoniaWeb, :html

  alias AlgedoniaWeb.Markdown

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

  def codex_normalize_model(model) do
    if Enum.any?(@codex_models, &(&1.id == model)), do: model, else: @default_model
  end

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
      supported_efforts: codex_efforts_for_model(codex_default_model()),
      chat_messages: [],
      chat_buffer: "",
      chat_split_pending: false
    }
  end

  def init_agent_ui(_agent_type) do
    %{
      supported_models: [],
      selected_model: nil,
      selected_effort: nil,
      supported_efforts: [],
      chat_messages: [],
      chat_buffer: "",
      chat_split_pending: false
    }
  end

  def apply_model_change(assigns, model) do
    model = codex_normalize_model(model)
    efforts = codex_efforts_for_model(model)

    effort =
      if assigns.selected_effort in efforts do
        assigns.selected_effort
      else
        hd(efforts)
      end

    %{selected_model: model, supported_efforts: efforts, selected_effort: effort}
  end

  def apply_effort_change(assigns, effort) do
    selected =
      if effort in assigns.supported_efforts do
        effort
      else
        List.first(assigns.supported_efforts)
      end

    %{selected_effort: selected}
  end

  attr :terminal_run_key, :string, required: true
  attr :chat_messages, :list, default: []

  def codex_chat_panel(assigns) do
    ~H"""
    <div
      id={"chat-stream-#{@terminal_run_key}"}
      phx-hook="ChatStream"
      class="h-full overflow-y-auto px-3 py-3 space-y-2"
    >
      <div :if={Enum.empty?(@chat_messages)} class="text-sm text-fg-muted">
        Chat will appear here once the agent starts responding.
      </div>
      <div
        :for={message <- @chat_messages}
        class={["max-w-[90%] space-y-1", if(message.role == "user", do: "ml-auto", else: "mr-auto")]}
      >
        <div class="text-[10px] uppercase tracking-wide text-fg-muted px-1">
          {chat_label(message)}
        </div>
        <div class={[
          "rounded-xl px-3 py-2 text-sm leading-relaxed whitespace-pre-wrap",
          bubble_class(message)
        ]}>
          <%= cond do %>
            <% message.role == "user" -> %>
              {message.text}
            <% message.kind == "command" -> %>
              <pre class="font-mono text-xs overflow-x-auto"><code>{message.text}</code></pre>
            <% message.kind == "reasoning" -> %>
              <span class="text-fg-muted">{message.text}</span>
            <% true -> %>
              {Markdown.render(message.text)}
          <% end %>
        </div>
      </div>
    </div>
    <div
      id={"terminal-#{@terminal_run_key}"}
      phx-hook="XTerm"
      phx-update="ignore"
      class="hidden"
    >
    </div>
    """
  end

  attr :terminal_run_key, :string, required: true

  def claude_terminal_panel(assigns) do
    ~H"""
    <div
      id={"terminal-#{@terminal_run_key}"}
      phx-hook="XTerm"
      phx-update="ignore"
      class="h-full"
    >
    </div>
    """
  end

  attr :terminal_run_key, :string, required: true
  attr :history, :list, default: []
  attr :active, :boolean, required: true
  attr :supported_models, :list, default: []
  attr :selected_model, :string, required: true
  attr :supported_efforts, :list, default: []
  attr :selected_effort, :string, required: true

  def codex_composer(assigns) do
    ~H"""
    <div class="border-t border-border-soft px-3 py-3 bg-[#0a0d12] space-y-2">
      <div class="h-11 rounded-xl border border-border-soft bg-[#171a20] px-4 flex items-center justify-between text-fg-muted">
        <div class="flex items-center gap-3 text-sm">
          <.icon name="hero-command-line" class="size-4" />
          <span class="text-fg-secondary">
            Running {running_terminal_count(@history)} terminal{if running_terminal_count(@history) ==
                                                                     1,
                                                                   do: "",
                                                                   else: "s"}
          </span>
        </div>
        <button
          :if={@active}
          phx-click="stop_loop"
          type="button"
          class="inline-flex items-center gap-2 text-fg-secondary hover:text-fg transition-colors"
        >
          <.icon name="hero-stop-mini" class="size-4" />
          <span class="text-sm">Stop</span>
        </button>
      </div>

      <.form
        for={%{}}
        as={:agent_message}
        phx-submit="send_agent_message"
        class="rounded-3xl border border-border bg-[#15181f] shadow-[0_8px_20px_rgba(0,0,0,0.35)]"
      >
        <div class="px-5 pt-4 pb-2">
          <textarea
            id={"agent-message-#{@terminal_run_key}"}
            name="agent_message[text]"
            rows="2"
            phx-hook="AutoResize"
            data-chat-composer="true"
            placeholder="Ask for follow-up changes"
            autocomplete="off"
            class="w-full resize-none border-0 bg-transparent p-0 text-base leading-relaxed text-fg placeholder:text-fg-muted/60 focus:outline-none"
          ></textarea>
        </div>

        <div class="h-12 px-4 flex items-center justify-between border-t border-border-soft/80">
          <div class="flex items-center gap-5 text-fg-muted">
            <button type="button" class="hover:text-fg transition-colors">
              <.icon name="hero-plus" class="size-5" />
            </button>
            <select
              phx-change="set_model"
              name="model"
              class="bg-transparent text-sm text-fg-muted hover:text-fg transition-colors focus:outline-none"
            >
              <option
                :for={model <- @supported_models}
                value={model.id}
                selected={model.id == @selected_model}
              >
                {model.label}
              </option>
            </select>
            <select
              phx-change="set_effort"
              name="effort"
              class="bg-transparent text-sm text-fg-muted hover:text-fg transition-colors focus:outline-none"
            >
              <option
                :for={effort <- @supported_efforts}
                value={effort}
                selected={effort == @selected_effort}
              >
                {String.capitalize(effort)}
              </option>
            </select>
          </div>

          <div class="flex items-center gap-3">
            <button type="button" class="text-fg-muted hover:text-fg transition-colors">
              <.icon name="hero-microphone" class="size-5" />
            </button>
            <button
              :if={!@active}
              type="submit"
              class="size-9 rounded-full bg-white text-black flex items-center justify-center hover:scale-105 transition-transform"
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </button>
            <button
              :if={@active}
              type="button"
              phx-click="stop_loop"
              class="size-9 rounded-full bg-white text-black flex items-center justify-center hover:scale-105 transition-transform"
            >
              <.icon name="hero-stop-mini" class="size-4" />
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp running_terminal_count(history) do
    Enum.count(history, fn entry -> entry.status == "running" end)
  end

  defp chat_label(%{role: "user"}), do: "You"
  defp chat_label(%{kind: "command"}), do: "Command"
  defp chat_label(%{kind: "reasoning"}), do: "Reasoning"
  defp chat_label(_), do: "Agent"

  defp bubble_class(%{role: "user"}) do
    "bg-accent-indigo/20 border border-accent-indigo/40 text-fg"
  end

  defp bubble_class(%{kind: "command"}) do
    "bg-[#0f131b] border border-border-soft text-fg-secondary"
  end

  defp bubble_class(%{kind: "reasoning"}) do
    "bg-surface border border-border-soft text-fg-muted"
  end

  defp bubble_class(_) do
    "bg-surface-panel border border-border text-fg-secondary markdown"
  end
end
