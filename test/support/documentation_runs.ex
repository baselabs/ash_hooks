defmodule AshHooks.Test.DocumentationRuns do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def completed(test, names), do: GenServer.call(__MODULE__, {:completed, test, names})
  def finished(test), do: GenServer.call(__MODULE__, {:finished, test})
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

  def handle_call({:finished, %{state: nil, module: module, name: name}}, _from, state) do
    {:reply, :ok, %{state | passed: MapSet.put(state.passed, {module, name})}}
  end

  def handle_call({:finished, _test}, _from, state), do: {:reply, :ok, state}
end

defmodule AshHooks.Test.DocumentationFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_options), do: {:ok, nil}

  @impl true
  def handle_cast({:test_finished, test}, state) do
    AshHooks.Test.DocumentationRuns.finished(test)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
