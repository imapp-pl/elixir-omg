# Copyright 2019-2020 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.RocksDBTest do
  @moduledoc """
  A smoke test of the RocksDB support. The intention here is to **only** test minimally, that the pipes work.

  For more detailed persistence test look for `...PersistenceTest` tests throughout the apps.

  Note the excluded moduletag, this test requires an explicit `--include wrappers`
  """
  use ExUnitFixtures
  use OMG.DB.RocksDBCase, async: false

  alias OMG.DB

  @moduletag :wrappers
  @moduletag :common
  @writes 10

  test "rocks db handles object storage", %{db_dir: dir, db_pid: pid} do
    :ok =
      DB.multi_update(
        [{:put, :block, %{hash: "xyz"}}, {:put, :block, %{hash: "vxyz"}}, {:put, :block, %{hash: "wvxyz"}}],
        pid
      )

    assert {:ok, [%{hash: "wvxyz"}, %{hash: "xyz"}]} == DB.blocks(["wvxyz", "xyz"], pid)

    :ok = DB.multi_update([{:delete, :block, "xyz"}], pid)

    checks = fn pid ->
      assert {:ok, [%{hash: "wvxyz"}, :not_found, %{hash: "vxyz"}]} == DB.blocks(["wvxyz", "xyz", "vxyz"], pid)
    end

    checks.(pid)

    # check actual persistence
    pid = restart(dir, pid)
    checks.(pid)
  end

  test "rocks db handles single value storage", %{db_dir: dir, db_pid: pid} do
    :ok = DB.multi_update([{:put, :last_exit_finalizer_eth_height, 12}], pid)

    checks = fn pid ->
      assert {:ok, 12} == DB.get_single_value(:last_exit_finalizer_eth_height, pid)
    end

    checks.(pid)
    # check actual persistence
    pid = restart(dir, pid)
    checks.(pid)
  end

  test "block hashes return the correct range", %{db_dir: _dir, db_pid: pid} do
    :ok =
      DB.multi_update(
        [
          {:put, :block, %{hash: "xyz", number: 1}},
          {:put, :block, %{hash: "vxyz", number: 2}},
          {:put, :block, %{hash: "wvxyz", number: 3}}
        ],
        pid
      )

    {:ok, ["xyz", "vxyz", "wvxyz"]} = OMG.DB.block_hashes([1, 2, 3], pid)
  end

  describe "batch_get" do
    test "can get single data with the type and single specific key", %{db_dir: _dir, db_pid: pid} do
      type = :exit_info
      specific_key = {1, 1, 1}
      data = {specific_key, :crypto.strong_rand_bytes(123)}
      :ok = DB.multi_update([{:put, type, data}], pid)

      assert {:ok, [data]} == DB.batch_get(type, [specific_key], server: pid)
    end

    test "can get multiple data with the type and multiple specific keys", %{db_dir: _dir, db_pid: pid} do
      type = :exit_info
      specific_keys = [{1, 1, 1}, {2, 2, 2}]
      data_list = Enum.map(specific_keys, fn key -> {key, :crypto.strong_rand_bytes(123)} end)

      :ok =
        data_list
        |> Enum.map(fn data -> {:put, type, data} end)
        |> DB.multi_update(pid)

      assert {:ok, data_list} == DB.batch_get(type, specific_keys, server: pid)
    end
  end

  test "it can get all data with the type", %{db_dir: _dir, db_pid: pid} do
    db_writes = create_write(:utxo, pid)

    assert {:ok, db_writes} == DB.get_all_by_type(:utxo, server: pid)
  end

  test "if multi reading utxos returns writen results", %{db_dir: _dir, db_pid: pid} do
    db_writes = create_write(:utxo, pid)
    {:ok, utxos} = DB.utxos(pid)
    [] = utxos -- db_writes
  end

  test "if multi reading competitor infos returns writen results", %{db_dir: _dir, db_pid: pid} do
    db_writes = create_write(:competitor_info, pid)
    {:ok, competitors_info} = DB.competitors_info(pid)
    [] = competitors_info -- db_writes
  end

  defp create_write(:utxo = type, pid) do
    db_writes =
      Enum.map(1..@writes, fn index ->
        {:put, type, {{index, index, index}, %{test: :crypto.strong_rand_bytes(index)}}}
      end)

    :ok = write(db_writes, pid)
    get_raw_values(db_writes)
  end

  defp create_write(:competitor_info = type, pid) do
    db_writes = Enum.map(1..@writes, fn index -> {:put, type, {:crypto.strong_rand_bytes(index), index}} end)

    :ok = write(db_writes, pid)
    get_raw_values(db_writes)
  end

  defp write(db_writes, pid), do: OMG.DB.multi_update(db_writes, pid)
  defp get_raw_values(db_writes), do: Enum.map(db_writes, &elem(&1, 2))

  defp restart(dir, pid) do
    :ok = GenServer.stop(pid)
    name = :"TestDB_#{make_ref() |> inspect()}"
    {:ok, pid} = start_supervised(OMG.DB.child_spec(db_path: dir, name: name), restart: :temporary)
    pid
  end


  describe "get utxos owned by address" do
    alias OMG.Crypto
    alias OMG.Utxo
    alias OMG.Utxo.Position
    alias OMG.State.UtxoSet
    alias OMG.Output

    require Utxo

    @tag timeout: 180_000
    test "perf test", %{db_dir: _dir, db_pid: pid} do
      blknum = 2 * 1000 * 1000 * 1000
      start = Utxo.position(blknum, 0, 0) |> Utxo.Position.encode()
      how_many_utxos = 193_731
      how_many_addr = div(how_many_utxos, 15) # each address has ~15 utxos

      IO.puts "Start test with #{how_many_utxos} utxos and #{how_many_addr} addresses."

      {gen_duration, utxo_pos_pairs} = :timer.tc(fn ->
        create_utxo_outputs(start, how_many_utxos, how_many_addr)
      end)
      IO.puts "Generation of #{how_many_utxos} utxos took #{round(gen_duration / 1000)}ms."

      uniq_addrs =
        utxo_pos_pairs
        |> Enum.take(how_many_addr)
        |> Enum.map(&extract_owner/1)
        |> MapSet.new()

      {map_duration, db_updates} = :timer.tc(fn ->
        create_utxo_db_put(Map.new(utxo_pos_pairs))
      end)
      IO.puts "Preparing utxo set for multi_update form took #{round(map_duration / 1000)}ms."

      # populate utxo set
      {duration, _} = :timer.tc(fn ->
        db_updates
        |> Stream.chunk_every(50_000)
        |> Enum.each(fn chunk ->
          :ok = OMG.DB.multi_update(chunk, pid)
        end)
      end)
      IO.puts "Writing whole utxo set in chunks took #{round(duration / 1000)}ms."

      # sanity check: try to fetch utxos from db at random
      start
      |> test_cases(how_many_utxos, 100)
      |> Enum.each(fn pointer ->
          assert {:ok, {^pointer, %{}}} = OMG.DB.utxo(pointer, pid)
      end)

      partitions = partition_addresses(uniq_addrs)
      partition_count = Enum.count(partitions)
      addrs_in_partition = div(Enum.count(uniq_addrs), partition_count)

      # We most likely won't get perfecly equal distribution, so get at least big enough group
      {pkey, paddrs} = Enum.find(partitions, fn {_, addrs} -> Enum.count(addrs) >= addrs_in_partition+2 end)
      IO.puts "Chosen partition of pkey=#{pkey} with #{Enum.count(paddrs)} addresses."

      in_group_fn = &(pkey == get_partition_key(&1, partition_count))
      {duration, addr_pos_pairs} = :timer.tc(fn ->
        {map, _fn} = Enum.reduce(utxo_pos_pairs, {%{}, in_group_fn}, &revert_to_addr_pos_pair/2)
        map
      end)

      positions_from_chosen_group =
        addr_pos_pairs
        |> Map.values()
        |> Enum.reduce(fn addr_pos, acc -> addr_pos ++ acc end)

      IO.puts "Extracted #{Enum.count(positions_from_chosen_group)} positions beloning to addresses partition of pkey=#{
        pkey
      }. It tooks #{round(duration / 1000)} ms to revert the mapping from the whole UTXO set"

      # sanity check - I can write and read partition position back
      {write_duration, :ok} = :timer.tc(fn ->
        OMG.DB.multi_update([{:put, :address_partition, {pkey, positions_from_chosen_group}}], pid)
      end)
      {read_duration, pos_list} = :timer.tc(fn ->
        {:ok, {_pkey, lst}} = GenServer.call(pid, {:address_partition, pkey})
        lst
      end)

      IO.puts "Partition list written in #{write_duration}μs and read back in #{read_duration}μs."

      assert positions_from_chosen_group == pos_list

      # check how fast is getting all utxos from the list and filter the chosen owner
      utxo_keys = Enum.map(positions_from_chosen_group, &extract_pointer/1)

      {duration, {:ok, pointer_utxos_pairs}} = :timer.tc(fn ->
        OMG.DB.batch_get(:utxo, utxo_keys, server: pid)
      end)
      IO.puts "Fetched all #{Enum.count(pointer_utxos_pairs)} utxos for addresses group in #{round(duration / 1000)}ms."

      # sanity check: filter with chosen address and compare with map
      [chosen_addr | _] = Map.keys(addr_pos_pairs)
      {duration, pairs} = :timer.tc(fn ->
          pointer_utxos_pairs
          |> Enum.filter(fn pointer_utxo_pair ->
            chosen_addr == extract_owner(pointer_utxo_pair)
          end)
      end)
      IO.puts "Filtering list of DB fetched utxos took #{duration}μs."

      pointers_from_db =
        pairs
        |> Enum.map(fn {pointer, _utxo} -> pointer end)
        |> MapSet.new()

      pointers_from_addr =
        addr_pos_pairs
        |> Map.get(chosen_addr)
        |> Enum.map(&extract_pointer/1)
        |> MapSet.new()

      assert MapSet.equal?(pointers_from_db, pointers_from_addr)
    end

    defp create_utxo_outputs(start, how_many_utxos, how_many_addr) do
      create_utxo_pos_pairs(start, how_many_utxos)
      |> Enum.map(fn {pos, utxo_pos} ->
        {utxo_pos, create_output(pos, how_many_addr)}
      end)
      |> Enum.map(fn {utxo_pos, o} ->
        {utxo_pos, create_utxo({utxo_pos, o})}
      end)
    end

    defp create_utxo_pos_pairs(start, how_many) do
      1..how_many
      |> Enum.map(fn i ->
        {:ok, pos} = Position.decode(start+i)
        {start+i, pos}
      end)
    end

    defp create_output(pos, how_many_addr) do
      currency = <<0::160>>
      amount = Integer.mod(pos, how_many_addr)
      <<owner::20-binary, _::binary>> = Crypto.hash("address-#{amount}")

      %Output{
        output_type: 1,
        owner: owner,
        currency: currency,
        amount: amount
      }
    end

    defp create_utxo({utxo_pos, output}) do
      %Utxo{
        output: output,
        creating_txhash: "hash-#{output.amount}-oi#{elem(utxo_pos, 3)}"
      }
    end

    defp create_utxo_db_put(utxos_map) do
      UtxoSet.db_updates([], utxos_map)
    end

    defp extract_pointer(pos) do
      pos |> Position.decode() |> elem(1) |> Position.to_input_db_key()
    end

    defp extract_owner(utxo_pos_pair) do
      {_upos, %{output: %{owner: owner}}} = utxo_pos_pair
      owner
    end

    defp get_partition_key(<<_::160>> = addr, partition_count) when is_integer(partition_count) do
      <<p::size(32), _rest::binary>> = addr
      Integer.mod(p, partition_count)
    end

    defp partition_addresses(addrs) do
      count = Enum.count(addrs)
      partition_count = 2 + div(count, 10) # about 10% of address space

      partitions =
        addrs
        |> Enum.reduce(%{}, fn addr, map ->
          pkey = get_partition_key(addr, partition_count)
          Map.update(map, pkey, [], fn lst -> [addr | lst] end)
        end)

      # Print distribution addresses into partitions
      # pcounts = partitions |> Enum.map(fn {_, lst} -> Enum.count(lst) end)
      # IO.puts "Distribution of addresses in #{partition_count} partitions, min: #{Enum.min(pcounts)} max: #{Enum.max(pcounts)}"

      partitions
    end

    defp revert_to_addr_pos_pair({utxo_pos, _utxo} = pair, {map, addr_in_group_fn}) do
      pos = Position.encode(utxo_pos)
      addr = extract_owner(pair)

      if addr_in_group_fn.(addr) do
        {Map.update(map, addr, [], fn lst -> [pos | lst] end), addr_in_group_fn}
      else
        {map, addr_in_group_fn}
      end
    end

    defp test_cases(start, how_many_utxos, how_many_tests) do
      fn -> start + :rand.uniform(how_many_utxos) end
      |> Stream.repeatedly()
      |> Stream.map(&extract_pointer/1)
      |> Enum.take(how_many_tests)
    end
  end
end
