defmodule Algedonia.Agents do
  @moduledoc """
  Centralized coding-agent defaults and normalization.
  """

  @valid_atoms [:codex, :claude_code]

  @spec default_coding_agent() :: atom()
  def default_coding_agent do
    Application.get_env(:algedonia, :default_coding_agent, :claude_code)
    |> normalize_agent_atom()
  end

  @spec default_coding_agent_string() :: String.t()
  def default_coding_agent_string do
    default_coding_agent() |> Atom.to_string()
  end

  @spec normalize_agent_atom(any()) :: atom()
  def normalize_agent_atom(agent) when agent in @valid_atoms, do: agent
  def normalize_agent_atom("codex"), do: :codex
  def normalize_agent_atom("claude_code"), do: :claude_code
  def normalize_agent_atom(_), do: :claude_code

  @doc """
  Returns the agent type string for a ticket based on its `coding_agent` field.
  """
  @spec ticket_agent_type(map()) :: String.t()
  def ticket_agent_type(%{coding_agent: :codex}), do: "codex"
  def ticket_agent_type(%{coding_agent: :claude_code}), do: "claude_code"
  def ticket_agent_type(_ticket), do: default_coding_agent_string()
end
