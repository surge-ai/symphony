defmodule SymphonyElixir.Linear.PrAutoClose do
  @moduledoc """
  Detects Linear issues that have transitioned to a Cancel-like terminal
  state and closes their attached GitHub PRs.

  Replaces the webhook-in-product-app approach from the canceled NTHPMV-79
  PR. The orchestrator already polls Linear every tick; we piggyback on
  that cadence, fetch issues whose state is in `{Canceled, Cancelled,
  Duplicate}`, ask Linear for each one's attachments, and close any
  attached GitHub PRs via the GitHub REST API. `Done` is intentionally
  excluded — Done usually means "merged via the `land` skill", and we
  must not retro-close a PR that has already merged.

  On boot, the first sweep is a no-op close-wise: we record every
  currently-terminal issue into the seen-set so we don't retroactively
  close PRs that were already attached to long-canceled tickets. From
  then on, only newly-terminal issues are processed.

  In-memory state is fine. PRs that close once stay closed; a Symphony
  restart re-seeds the seen-set on the next sweep, so the worst case
  after a restart is "any issue canceled while Symphony was down stays
  un-acted-upon" — re-cancel or close the PR manually.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Tracker

  @attachment_query """
  query SymphonyPrAutoCloseAttachments($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      attachments(first: $first) {
        nodes {
          url
        }
      }
    }
  }
  """

  @cancel_states ["Canceled", "Cancelled", "Duplicate"]
  @attachment_page_size 50
  @gh_api_root "https://api.github.com"
  @http_timeout_ms 15_000

  defmodule State do
    @moduledoc false
    defstruct seen: MapSet.new(), initialized: false
  end

  # ---- Public ---------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Trigger a sweep. Called by the orchestrator at the end of each poll cycle.
  Cast so the orchestrator never blocks on Linear/GitHub I/O here.
  """
  @spec sweep() :: :ok
  def sweep do
    GenServer.cast(__MODULE__, :sweep)
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_cast(:sweep, %State{} = state) do
    {:noreply, run_sweep(state)}
  end

  # ---- Sweep core -----------------------------------------------------------

  defp run_sweep(%State{} = state) do
    case Tracker.fetch_issues_by_states(@cancel_states) do
      {:ok, issues} ->
        case state do
          %State{initialized: false} ->
            seen = MapSet.new(issues, & &1.id)

            SymphonyElixir.Datadog.event("symphony.pr_auto_close.backfill",
              already_terminal: MapSet.size(seen)
            )

            %State{state | seen: seen, initialized: true}

          %State{initialized: true} ->
            Enum.reduce(issues, state, &maybe_process_issue/2)
        end

      {:error, reason} ->
        Logger.debug("PrAutoClose: skipped sweep, fetch failed: #{inspect(reason)}")
        state
    end
  end

  defp maybe_process_issue(%{id: id} = issue, %State{seen: seen} = state) when is_binary(id) do
    if MapSet.member?(seen, id) do
      state
    else
      process_issue(issue)
      %State{state | seen: MapSet.put(seen, id)}
    end
  end

  defp maybe_process_issue(_issue, state), do: state

  defp process_issue(issue) do
    case fetch_pr_attachments(issue.id) do
      {:ok, prs} when prs != [] ->
        Enum.each(prs, &close_pr(&1, issue))

      {:ok, []} ->
        SymphonyElixir.Datadog.event("symphony.pr_auto_close.no_pr",
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          state: issue.state
        )

      {:error, reason} ->
        Logger.warning("PrAutoClose: attachment lookup failed for #{issue.identifier}: #{inspect(reason)}")

        SymphonyElixir.Datadog.event("symphony.pr_auto_close.lookup_failed",
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          reason: inspect(reason) |> String.slice(0, 200)
        )
    end
  end

  defp fetch_pr_attachments(issue_id) when is_binary(issue_id) do
    case linear_client().graphql(@attachment_query, %{
           issueId: issue_id,
           first: @attachment_page_size
         }) do
      {:ok, body} ->
        nodes = get_in(body, ["data", "issue", "attachments", "nodes"]) || []

        prs =
          nodes
          |> Enum.map(& &1["url"])
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&parse_pr_url/1)
          |> Enum.uniq()

        {:ok, prs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec parse_pr_url(String.t()) :: [{String.t(), String.t(), pos_integer()}]
  def parse_pr_url(url) when is_binary(url) do
    case Regex.run(~r{\Ahttps?://github\.com/([^/]+)/([^/]+)/pull/(\d+)\b}, url) do
      [_, owner, repo, number] ->
        case Integer.parse(number) do
          {n, _} when n > 0 -> [{owner, repo, n}]
          _ -> []
        end

      _ ->
        []
    end
  end

  def parse_pr_url(_), do: []

  defp close_pr({owner, repo, number}, issue) do
    state_label = issue.state || "Canceled"
    identifier = issue.identifier || "(unknown)"
    comment_body = "Closing — Linear ticket #{identifier} was #{state_label}."

    started_at = System.monotonic_time(:millisecond)

    with :ok <- post_comment(owner, repo, number, comment_body),
         :ok <- close_pull_request(owner, repo, number) do
      SymphonyElixir.Datadog.event("symphony.pr_auto_close.closed",
        issue_id: issue.id,
        issue_identifier: identifier,
        state: state_label,
        owner: owner,
        repo: repo,
        pull_number: number,
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      Logger.info("PrAutoClose: closed PR #{owner}/#{repo}##{number} for #{identifier} (#{state_label})")
    else
      {:error, reason} ->
        SymphonyElixir.Datadog.event("symphony.pr_auto_close.close_failed",
          issue_id: issue.id,
          issue_identifier: identifier,
          owner: owner,
          repo: repo,
          pull_number: number,
          reason: inspect(reason) |> String.slice(0, 200)
        )

        Logger.warning("PrAutoClose: failed to close PR #{owner}/#{repo}##{number} for #{identifier}: #{inspect(reason)}")
    end
  end

  defp post_comment(owner, repo, number, body) do
    url = "#{@gh_api_root}/repos/#{owner}/#{repo}/issues/#{number}/comments"
    gh_post(url, %{body: body}, :comment)
  end

  defp close_pull_request(owner, repo, number) do
    url = "#{@gh_api_root}/repos/#{owner}/#{repo}/pulls/#{number}"
    gh_patch(url, %{state: "closed"}, :close)
  end

  defp gh_post(url, body, kind) do
    case gh_token() do
      {:ok, token} ->
        Req.post(url,
          headers: gh_headers(token),
          json: body,
          connect_options: [timeout: @http_timeout_ms],
          receive_timeout: @http_timeout_ms
        )
        |> interpret_gh_response(kind)

      :error ->
        {:error, :missing_gh_token}
    end
  end

  defp gh_patch(url, body, kind) do
    case gh_token() do
      {:ok, token} ->
        Req.patch(url,
          headers: gh_headers(token),
          json: body,
          connect_options: [timeout: @http_timeout_ms],
          receive_timeout: @http_timeout_ms
        )
        |> interpret_gh_response(kind)

      :error ->
        {:error, :missing_gh_token}
    end
  end

  defp interpret_gh_response({:ok, %{status: status}}, _kind) when status in 200..299, do: :ok

  defp interpret_gh_response({:ok, %{status: status, body: body}}, kind) do
    {:error, {:github_api, kind, status, summarize_body(body)}}
  end

  defp interpret_gh_response({:error, reason}, kind) do
    {:error, {:github_request, kind, reason}}
  end

  defp summarize_body(body) when is_binary(body) do
    body |> String.slice(0, 200)
  end

  defp summarize_body(body) do
    body |> inspect() |> String.slice(0, 200)
  end

  defp gh_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"User-Agent", "symphony-pr-auto-close"}
    ]
  end

  defp gh_token do
    case System.get_env("GH_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp linear_client do
    Application.get_env(:symphony_elixir, :linear_client_module, SymphonyElixir.Linear.Client)
  end
end
