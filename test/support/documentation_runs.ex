defmodule AshHooks.Test.DocumentationRuns do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def completed(test, names), do: GenServer.call(__MODULE__, {:completed, test, names})
  def completed_names, do: GenServer.call(__MODULE__, :completed_names)

  @impl true
  def init(_options), do: {:ok, %{runs: %{}, passed: MapSet.new()}}

  @impl true
  def handle_call({:completed, test, names}, _from, state) do
    runs = Map.update(state.runs, test, MapSet.new(names), &MapSet.union(&1, MapSet.new(names)))
    {:reply, :ok, %{state | runs: runs}}
  end

  def handle_call(:completed_names, _from, state) do
    names =
      state.runs
      |> Enum.filter(fn {test, _names} -> MapSet.member?(state.passed, test) end)
      |> Enum.flat_map(fn {_test, names} -> MapSet.to_list(names) end)
      |> Enum.uniq()

    {:reply, names, state}
  end

  @impl true
  def handle_cast({:test_finished, %{state: nil, module: module, name: name}}, state) do
    {:noreply, %{state | passed: MapSet.put(state.passed, {module, name})}}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
