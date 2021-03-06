defmodule TestHelper.TcpServer do
  @moduledoc false
  use GenServer

  defstruct [
    :socket,
    :listener,
    messages: :queue.new(),
    buffer: <<>>
  ]

  def pop(server \\ __MODULE__) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :pop, 1000)
  end

  def all(server \\ __MODULE__) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :all, 1000)
  end

  def listen(server \\ __MODULE__) when is_pid(server) or is_atom(server) do
    GenServer.call(server, :listen, 1000)
  end

  def init(args) do
    case :gen_tcp.listen(Keyword.get(args, :port, 22_000), [
           :binary,
           active: true,
           reuseaddr: true
         ]) do
      {:ok, listener} -> {:ok, %__MODULE__{listener: listener}, {:continue, :accept}}
      error -> error
    end
  end

  def handle_continue(:accept, %{listener: listener} = state) do
    server = self()

    spawn(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          Port.connect(socket, server)
          send(server, {:socket, socket})

        error ->
          send(server, {:socket, error})
      end

      receive do
        {:tcp, _, _} = msg ->
          send(server, msg)
      after
        10 ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:socket, socket}, state) do
    if is_port(socket) do
      {:noreply, %{state | socket: socket}}
    else
      {:noreply, state, {:continue, :accept}}
    end
  end

  def handle_info({:tcp, _port, msg}, state) do
    parse_buffer(%{state | buffer: state.buffer <> msg})
  end

  def handle_info({:tcp_closed, _port}, state) do
    {:noreply, %{state | socket: nil}}
  end

  defp parse_buffer(state) do
    case parse_stream(state.buffer) do
      {:ok, part, rest} ->
        package = Jason.decode!(part)
        parse_buffer(%{state | buffer: rest, messages: :queue.in(package, state.messages)})

      {:error, rest} ->
        {:noreply, %{state | buffer: rest}}
    end
  end

  def handle_call(:pop, _from, state) do
    case :queue.out(state.messages) do
      {:empty, queue} ->
        {:reply, nil, %{state | messages: queue}}

      {{:value, item}, queue} ->
        {:reply, item, %{state | messages: queue}}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, :queue.to_list(state.messages), %{state | messages: :queue.new()}}
  end

  def handle_call(:listen, _from, state) do
    {:reply, :ok, state, {:continue, :accept}}
  end

  defp parse_stream(stream, acc \\ [])

  defp parse_stream(<<0::8, rest::binary>>, acc) do
    {:ok, acc_to_binary(acc), rest}
  end

  defp parse_stream(<<any::8, rest::binary>>, acc) do
    parse_stream(rest, [any | acc])
  end

  defp parse_stream(<<>>, acc) do
    {:error, acc_to_binary(acc)}
  end

  defp acc_to_binary(acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  def terminate(_, state) do
    if state.listener, do: :gen_tcp.close(state.listener)
    if state.socket, do: :gen_tcp.close(state.socket)
  end
end
