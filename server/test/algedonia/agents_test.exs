defmodule Algedonia.AgentsTest do
  use ExUnit.Case, async: true

  alias Algedonia.Agents

  describe "ticket_agent_type/1" do
    test "returns codex for codex ticket" do
      assert Agents.ticket_agent_type(%{coding_agent: :codex}) == "codex"
    end

    test "returns claude_code for claude_code ticket" do
      assert Agents.ticket_agent_type(%{coding_agent: :claude_code}) == "claude_code"
    end

    test "returns default for nil coding_agent" do
      assert Agents.ticket_agent_type(%{coding_agent: nil}) ==
               Agents.default_coding_agent_string()
    end

    test "returns default for unknown coding_agent" do
      assert Agents.ticket_agent_type(%{}) == Agents.default_coding_agent_string()
    end
  end

  describe "normalize_agent_atom/1" do
    test "normalizes string to atom" do
      assert Agents.normalize_agent_atom("codex") == :codex
      assert Agents.normalize_agent_atom("claude_code") == :claude_code
    end

    test "passes through valid atoms" do
      assert Agents.normalize_agent_atom(:codex) == :codex
      assert Agents.normalize_agent_atom(:claude_code) == :claude_code
    end

    test "defaults unknown values to codex" do
      assert Agents.normalize_agent_atom("unknown") == :codex
      assert Agents.normalize_agent_atom(nil) == :codex
    end
  end
end
