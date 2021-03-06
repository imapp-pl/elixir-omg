# Copyright 2019-2020 OMG Network Pte Ltd
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

defmodule OMG.Watcher.ExitProcessor.CoreTest do
  @moduledoc """
  Test of the logic of exit processor - various generic tests: starting events, some sanity checks, ife listing
  """
  use OMG.Watcher.ExitProcessor.Case, async: true

  alias OMG.Block
  alias OMG.State.Transaction
  alias OMG.TestHelper
  alias OMG.Utxo
  alias OMG.Watcher.ExitProcessor
  alias OMG.Watcher.ExitProcessor.Core
  alias OMG.Watcher.ExitProcessor.InFlightExitInfo

  require Utxo

  import OMG.Watcher.ExitProcessor.TestHelper
  import ExUnit.CaptureLog, only: [capture_log: 1]

  @eth OMG.Eth.zero_address()

  @late_blknum 10_000

  @utxo_pos1 Utxo.position(2, 0, 0)
  @utxo_pos2 Utxo.position(@late_blknum - 1_000, 0, 1)

  describe "generic sanity checks" do
    test "can start new standard exits one by one or batched", %{processor_empty: empty, alice: alice, bob: bob} do
      standard_exit_tx1 = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 10}])
      standard_exit_tx2 = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{bob, 10}, {bob, 10}])
      {event1, status1} = se_event_status(standard_exit_tx1, @utxo_pos1)
      {event2, status2} = se_event_status(standard_exit_tx2, @utxo_pos2)
      events = [event1, event2]
      statuses = [status1, status2]

      {state2, _} = Core.new_exits(empty, Enum.slice(events, 0, 1), Enum.slice(statuses, 0, 1))
      {final_state, _} = Core.new_exits(empty, events, statuses)
      assert {^final_state, _} = Core.new_exits(state2, Enum.slice(events, 1, 1), Enum.slice(statuses, 1, 1))
    end

    test "new_exits sanity checks", %{processor_empty: processor} do
      {:error, :unexpected_events} = processor |> Core.new_exits([:anything], [])
      {:error, :unexpected_events} = processor |> Core.new_exits([], [:anything])
    end

    test "can process empty new exits, empty in flight exits",
         %{processor_empty: empty, processor_filled: filled} do
      assert {^empty, []} = Core.new_exits(empty, [], [])
      assert {^empty, []} = Core.new_in_flight_exits(empty, [], [])
      assert {^filled, []} = Core.new_exits(filled, [], [])
      assert {^filled, []} = Core.new_in_flight_exits(filled, [], [])
    end

    test "empty processor returns no exiting utxo positions", %{processor_empty: empty} do
      assert %ExitProcessor.Request{utxos_to_check: []} =
               Core.determine_utxo_existence_to_get(%ExitProcessor.Request{blknum_now: @late_blknum}, empty)
    end

    test "in flight exits sanity checks",
         %{processor_empty: state, in_flight_exit_events: events} do
      assert {state, []} == Core.new_in_flight_exits(state, [], [])
      assert {:error, :unexpected_events} == Core.new_in_flight_exits(state, Enum.slice(events, 0, 1), [])
      assert {:error, :unexpected_events} == Core.new_in_flight_exits(state, [], [{:anything, 1}])
    end

    test "knows exits by exit_id the moment they start",
         %{processor_empty: processor, alice: alice} do
      standard_exit_tx = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 10}])
      assert nil == Core.exit_key_by_exit_id(processor, 314)

      processor =
        processor
        |> start_se_from(standard_exit_tx, @utxo_pos1, exit_id: 314)

      assert @utxo_pos1 == Core.exit_key_by_exit_id(processor, 314)
      assert nil == Core.exit_key_by_exit_id(processor, 315)
    end

    test "knows exits by exit_id after challenging",
         %{processor_empty: processor, alice: alice} do
      standard_exit_tx = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 10}])

      {processor, _} =
        processor
        |> start_se_from(standard_exit_tx, @utxo_pos1, exit_id: 314)
        |> Core.challenge_exits([%{utxo_pos: Utxo.Position.encode(@utxo_pos1)}])

      assert @utxo_pos1 == Core.exit_key_by_exit_id(processor, 314)
    end

    test "doesn't know ife by exit_id because NOT IMPLEMENTED, remove when it's implemented",
         %{processor_empty: processor, alice: alice} do
      standard_exit_tx = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 10}])

      {processor, _} =
        processor
        |> start_ife_from(standard_exit_tx, exit_id: 314)
        |> Core.challenge_exits([%{utxo_pos: Utxo.Position.encode(@utxo_pos1)}])

      # because not implemented yet
      # TODO fix when implemented
      assert nil == Core.exit_key_by_exit_id(processor, 314)
    end
  end

  describe "check_sla_margin/4" do
    test "allows only safe margins if not forcing" do
      assert {:error, :sla_margin_too_big} = Core.check_sla_margin(10, false, 100, 15)
      assert :ok = Core.check_sla_margin(10, false, 300, 15)
    end

    test "allows anything if forcing" do
      capture_log(fn -> assert :ok = Core.check_sla_margin(10, true, 100, 15) end)
      assert :ok = Core.check_sla_margin(10, true, 300, 15)
    end
  end

  describe "active SE/IFE listing (only IFEs for now)" do
    test "properly processes new in flight exits, returns all of them on request",
         %{processor_empty: processor, in_flight_exit_events: events} do
      assert [] == Core.get_active_in_flight_exits(processor)
      # some statuses as received from the contract
      statuses = [{active_ife_status(), 1}, {active_ife_status(), 2}]

      {processor, _} = Core.new_in_flight_exits(processor, events, statuses)
      ifes_response = Core.get_active_in_flight_exits(processor)

      assert ifes_response |> Enum.count() == 2
    end

    test "correct format of getting all ifes",
         %{processor_filled: processor, transactions: [tx1, tx2 | _]} do
      assert [
               %{
                 txbytes: Transaction.raw_txbytes(tx1),
                 txhash: Transaction.raw_txhash(tx1),
                 eth_height: 1,
                 piggybacked_inputs: [],
                 piggybacked_outputs: []
               },
               %{
                 txbytes: Transaction.raw_txbytes(tx2),
                 txhash: Transaction.raw_txhash(tx2),
                 eth_height: 4,
                 piggybacked_inputs: [],
                 piggybacked_outputs: []
               }
             ] == Core.get_active_in_flight_exits(processor) |> Enum.sort_by(& &1.eth_height)
    end

    test "reports piggybacked inputs/outputs when getting ifes",
         %{processor_empty: processor, transactions: [tx | _]} do
      txhash = Transaction.raw_txhash(tx)
      processor = start_ife_from(processor, tx)
      assert [%{piggybacked_inputs: [], piggybacked_outputs: []}] = Core.get_active_in_flight_exits(processor)

      processor = piggyback_ife_from(processor, txhash, 0, :input)
      assert [%{piggybacked_inputs: [0], piggybacked_outputs: []}] = Core.get_active_in_flight_exits(processor)

      processor = processor |> piggyback_ife_from(txhash, 0, :output) |> piggyback_ife_from(txhash, 1, :output)
      assert [%{piggybacked_inputs: [0], piggybacked_outputs: [0, 1]}] = Core.get_active_in_flight_exits(processor)
    end

    test "challenges don't affect the list of IFEs returned",
         %{processor_filled: processor, transactions: [tx | _], competing_tx: comp} do
      assert Core.get_active_in_flight_exits(processor) |> Enum.count() == 2
      {processor2, _} = Core.new_ife_challenges(processor, [ife_challenge(tx, comp)])
      assert Core.get_active_in_flight_exits(processor2) |> Enum.count() == 2
      # sanity
      assert processor2 != processor
    end
  end

  describe "handling of spent blknums result" do
    test "asks for the right blocks when all are spent correctly" do
      assert [1000] = Core.handle_spent_blknum_result([{:ok, 1000}], [@utxo_pos1])
      assert [] = Core.handle_spent_blknum_result([], [])
      assert [2000, 1000] = Core.handle_spent_blknum_result([{:ok, 2000}, {:ok, 1000}], [@utxo_pos2, @utxo_pos1])
    end

    test "asks for blocks just once" do
      assert [1000] = Core.handle_spent_blknum_result([{:ok, 1000}, {:ok, 1000}], [@utxo_pos2, @utxo_pos1])
    end

    @tag :capture_log
    test "asks for the right blocks if some spends are missing" do
      assert [1000] = Core.handle_spent_blknum_result([:not_found, {:ok, 1000}], [@utxo_pos2, @utxo_pos1])
    end
  end

  describe "finding IFE txs in blocks" do
    test "handles well situation when syncing is in progress", %{processor_filled: state} do
      assert %ExitProcessor.Request{utxos_to_check: [], ife_input_utxos_to_check: []} =
               %ExitProcessor.Request{eth_height_now: 13, blknum_now: 0}
               |> Core.determine_ife_input_utxos_existence_to_get(state)
               |> Core.determine_utxo_existence_to_get(state)
    end

    test "seeks all IFE txs' inputs spends in blocks", %{processor_filled: processor, transactions: txs} do
      request = %ExitProcessor.Request{
        blknum_now: 5000,
        eth_height_now: 5
      }

      # for one piggybacked output, we're asking for its inputs positions to check utxo existence
      request = Core.determine_ife_input_utxos_existence_to_get(request, processor)
      expected_inputs = txs |> Enum.flat_map(&Transaction.get_inputs/1)
      assert Enum.sort(expected_inputs) == Enum.sort(request.ife_input_utxos_to_check)

      # if it turns out to not exists, we're fetching the spending block
      request =
        request
        |> struct!(%{ife_input_utxo_exists_result: [false, true, true, true]})
        |> Core.determine_ife_spends_to_get(processor)

      assert length(request.ife_input_spends_to_get) == 1
      assert hd(request.ife_input_spends_to_get) in expected_inputs
    end

    test "seeks IFE txs in blocks, correctly if IFE inputs duplicate",
         %{processor_filled: processor, alice: alice, transactions: txs} do
      other_tx = TestHelper.create_recovered([{1, 0, 0, alice}], [{alice, @eth, 1}])
      processor = start_ife_from(processor, other_tx)

      request = %ExitProcessor.Request{
        blknum_now: 5000,
        eth_height_now: 5
      }

      # for one piggybacked output, we're asking for its inputs positions to check utxo existence
      request = Core.determine_ife_input_utxos_existence_to_get(request, processor)
      expected_inputs = txs |> Enum.flat_map(&Transaction.get_inputs/1)

      assert Enum.sort(expected_inputs) == Enum.sort(request.ife_input_utxos_to_check)
    end

    test "seeks IFE txs in blocks only if not already found",
         %{processor_filled: processor, transactions: [tx1, tx2]} do
      request = %ExitProcessor.Request{
        blknum_now: 5000,
        eth_height_now: 5,
        ife_input_spending_blocks_result: [Block.hashed_txs_at([tx1], 3000)]
      }

      processor = processor |> Core.find_ifes_in_blocks(request)
      # for one piggybacked output, we're asking for its inputs positions to check utxo existence
      request = Core.determine_ife_input_utxos_existence_to_get(request, processor)

      expected_inputs = Transaction.get_inputs(tx2)
      assert Enum.sort(expected_inputs) == Enum.sort(request.ife_input_utxos_to_check)
    end
  end

  describe "active_standard_exiting_utxos" do
    test "returns a set of exiting utxo positions" do
      utxo_pos_active = {active_blknum, active_txindex, active_txoutput} = {1000, 0, 0}

      active_exit = %{
        amount: 1,
        block_timestamp: 1,
        currency: <<1::160>>,
        eth_height: 1,
        exit_id: 1,
        exiting_txbytes: "txbytes",
        is_active: true,
        owner: <<1::160>>,
        root_chain_txhash: <<1::256>>,
        scheduled_finalization_time: 2,
        spending_txhash: nil
      }

      utxo_pos_inactive = {1000, 0, 1}
      inactive_exit = Map.replace!(active_exit, :is_active, false)

      db_exits = [{utxo_pos_active, active_exit}, {utxo_pos_inactive, inactive_exit}]

      expected = MapSet.new([Utxo.position(active_blknum, active_txindex, active_txoutput)])

      assert expected == Core.active_standard_exiting_utxos(db_exits)
    end
  end

  describe "active_in_flight_exiting_inputs" do
    test "returns a set of exiting utxo positions" do
      expected_utxos = [Utxo.position(2001, 0, 0), Utxo.position(2002, 0, 0)]

      db_exits = [
        {<<1>>, prepare_fake_ife_db_kv(false, [Utxo.position(1001, 0, 0)])},
        {<<2>>, prepare_fake_ife_db_kv(true, expected_utxos)}
      ]

      assert MapSet.new(expected_utxos) == Core.active_in_flight_exiting_inputs(db_exits)
    end

    defp prepare_fake_ife_db_kv(is_active, utxos_pos) do
      raw_tx_map = %{tx_type: 1, inputs: [], outputs: [], metadata: <<0::256>>}
      signed_tx_map = %{raw_tx: raw_tx_map, sigs: []}
      utxo_pos = Utxo.position(0, 0, 0)

      db_value_map =
        %{
          tx: signed_tx_map,
          exit_map: %{},
          tx_pos: utxo_pos,
          oldest_competitor: utxo_pos,
          contract_id: <<1>>,
          timestamp: 0,
          eth_height: 100,
          relevant_from_blknum: 0,
          input_txs: [],
          input_utxos_pos: [],
          is_canonical: true,
          is_active: true
        }
        |> Map.update!(:is_active, fn _ -> is_active end)
        |> Map.update!(:input_utxos_pos, fn _ -> utxos_pos end)

      # sanity check - we need above date to be parsed correctly
      assert {<<1>>, %InFlightExitInfo{}} = InFlightExitInfo.from_db_kv({<<1>>, db_value_map})

      db_value_map
    end
  end

  describe "delete_in_flight_exits/2" do
    test "returns deleted utxos and database updates", %{processor_empty: processor, alice: alice} do
      ife_exit_tx1 = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 9}])
      ife_id1 = 1
      tx_hash1 = Transaction.raw_txhash(ife_exit_tx1)
      ife_exit_tx2 = TestHelper.create_recovered([{2, 0, 1, alice}, {2, 0, 2, alice}], @eth, [{alice, 9}])
      ife_id2 = 2
      ife_exit_tx3 = TestHelper.create_recovered([{3, 0, 1, alice}, {3, 0, 2, alice}], @eth, [{alice, 9}])
      ife_id3 = 3
      tx_hash3 = Transaction.raw_txhash(ife_exit_tx3)

      {_processor, deleted_utxos, db_updates} =
        processor
        |> start_ife_from(ife_exit_tx1, exit_id: ife_id1)
        |> start_ife_from(ife_exit_tx2, exit_id: ife_id2)
        |> start_ife_from(ife_exit_tx3, exit_id: ife_id3)
        |> Core.delete_in_flight_exits([%{exit_id: ife_id1}, %{exit_id: ife_id3}])

      assert Enum.sort(deleted_utxos) ==
               Enum.sort([{:utxo_position, 3, 0, 1}, {:utxo_position, 3, 0, 2}, {:utxo_position, 1, 0, 0}])

      assert Enum.sort(db_updates) ==
               Enum.sort([{:delete, :in_flight_exit_info, tx_hash1}, {:delete, :in_flight_exit_info, tx_hash3}])
    end

    test "deletes in-flight exits from processor", %{processor_empty: processor, alice: alice} do
      ife_exit_tx = TestHelper.create_recovered([{1, 0, 0, alice}], @eth, [{alice, 9}])
      ife_id = 1

      {processor, _deleted_utxos, _db_updates} =
        processor
        |> start_ife_from(ife_exit_tx, exit_id: ife_id)
        |> Core.delete_in_flight_exits([%{exit_id: ife_id}])

      assert Enum.empty?(processor.in_flight_exits)
    end
  end
end
