defmodule SymphonyElixir.Datadog do
  @moduledoc """
  Datadog log shipping for the Symphony harness.

  Every record is tagged so it can be partitioned from other entries
  in the shared Datadog account:

  * `service`  = `nickheiner-symphony`
  * `ddsource` = `nickheiner-symphony`
  * `ddtags`   = `service:nickheiner-symphony,app:nickheiner-symphony,env:prod`

  Filter scope-in:  `service:nickheiner-symphony`
  Filter scope-out: `-service:nickheiner-symphony`

  No-op when `DD_API_KEY` is unset (dev/test).
  """

  use GenServer
  require Logger

  @handler_id :datadog

  @intake_url "https://http-intake.logs.datadoghq.com/api/v2/logs"
  @flush_interval_ms 5_000
  @max_batch 500
  @http_timeout_ms 10_000

  @service "nickheiner-symphony"
  @ddsource "nickheiner-symphony"
  @ddtags "service:nickheiner-symphony,app:nickheiner-symphony,env:prod"

  # ---- Public ---------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Idempotently install the :logger handler. Skipped when DD_API_KEY is unset
  or when this GenServer didn't start (e.g. dev/test with no key).
  """
  def install_handler do
    cond do
      System.get_env("DD_API_KEY") == nil ->
        :ok

      Process.whereis(__MODULE__) == nil ->
        :ok

      true ->
        :logger.remove_handler(@handler_id)

        case :logger.add_handler(@handler_id, __MODULE__, %{
               level: :info,
               filter_default: :log
             }) do
          :ok -> :ok
          {:error, {:handler_not_added, {:already_exists, _}}} -> :ok
          {:error, reason} ->
            Logger.warning("Datadog log handler add failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  # ---- :logger handler callback ---------------------------------------------
  # The :logger handler protocol is `log/2` — we just forward to the GenServer
  # so the hot log path stays cheap and never blocks on HTTP.

  def log(event, _config) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:log, event})
      _ -> :ok
    end
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(_) do
    case System.get_env("DD_API_KEY") do
      nil ->
        # No key, no work. The handler install is also a no-op when this
        # process isn't running.
        :ignore

      api_key when is_binary(api_key) ->
        schedule_flush()
        {:ok, %{api_key: api_key, buffer: [], hostname: hostname()}}
    end
  end

  @impl true
  def handle_cast({:log, event}, state) do
    record = build_record(event, state.hostname)
    new_buffer = [record | state.buffer]

    if length(new_buffer) >= @max_batch do
      ship(Enum.reverse(new_buffer), state.api_key)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    state =
      case state.buffer do
        [] -> state
        records -> ship(Enum.reverse(records), state.api_key); %{state | buffer: []}
      end

    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort flush on shutdown.
    case state do
      %{buffer: [_ | _] = records, api_key: api_key} ->
        ship_sync(Enum.reverse(records), api_key)

      _ ->
        :ok
    end

    :ok
  end

  # ---- Internals ------------------------------------------------------------

  defp build_record(%{level: level, msg: msg, meta: meta}, hostname) do
    %{
      "service" => @service,
      "ddsource" => @ddsource,
      "ddtags" => @ddtags,
      "hostname" => hostname,
      "status" => to_string(level),
      "message" => format_msg(msg),
      "logger.module" => meta |> Map.get(:module) |> safe_to_string(),
      "logger.function" => meta |> Map.get(:function) |> safe_to_string(),
      "logger.file" => meta |> Map.get(:file) |> safe_to_string(),
      "logger.line" => meta |> Map.get(:line) |> safe_to_string()
    }
  end

  defp format_msg({:string, chardata}), do: IO.chardata_to_string(chardata)

  defp format_msg({:report, %{label: label, report: report}}),
    do: "#{inspect(label)} #{inspect(report)}"

  defp format_msg({:report, report}), do: inspect(report)
  defp format_msg(other) when is_binary(other), do: other
  defp format_msg(other), do: inspect(other)

  defp safe_to_string(nil), do: ""
  defp safe_to_string(v) when is_binary(v), do: v
  defp safe_to_string(v), do: inspect(v)

  defp ship(records, api_key) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      ship_sync(records, api_key)
    end)

    :ok
  end

  defp ship_sync(records, api_key) do
    try do
      Req.post(@intake_url,
        headers: [
          {"DD-API-KEY", api_key},
          {"content-type", "application/json"}
        ],
        json: records,
        retry: false,
        connect_options: [timeout: @http_timeout_ms]
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, host} -> List.to_string(host)
      _ -> "unknown"
    end
  end
end
