defmodule Algedonia.Accounts do
  @moduledoc """
  Context for user accounts.
  """
  alias Algedonia.Accounts.User
  alias Algedonia.Repo

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_name(name) do
    Repo.get_by(User, name: name)
  end

  def get_or_create_user(%{name: name} = attrs) when is_binary(name) do
    case get_user_by_name(name) do
      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end
end
