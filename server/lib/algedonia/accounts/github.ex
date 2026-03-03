defmodule Algedonia.Accounts.GitHub do
  @moduledoc """
  GitHub API wrapper for user-scoped operations during onboarding.
  """

  @repos_url "https://api.github.com/user/repos"

  @doc """
  Lists repositories for the authenticated GitHub user.

  Returns `{:ok, repos}` where each repo is a map with `:name`, `:full_name`,
  `:html_url`, `:private`, and `:description` keys.

  Returns `{:error, reason}` if the API call fails.
  """
  @spec list_user_repos(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_user_repos(access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case Req.get(@repos_url, headers: headers, params: [sort: "updated", per_page: 50]) do
      {:ok, %{status: 200, body: repos}} when is_list(repos) ->
        {:ok, Enum.map(repos, &normalize_repo/1)}

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned #{status}"}

      {:error, reason} ->
        {:error, "GitHub API request failed: #{inspect(reason)}"}
    end
  end

  defp normalize_repo(repo) do
    %{
      name: repo["name"],
      full_name: repo["full_name"],
      html_url: repo["html_url"],
      private: repo["private"],
      description: repo["description"]
    }
  end
end
