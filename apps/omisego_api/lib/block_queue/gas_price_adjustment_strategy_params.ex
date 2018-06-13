defmodule OmiseGO.API.BlockQueue.GasPriceAdjustmentStrategyParams do
  @moduledoc """
  Encapsulates the Eth gas price adjustment strategy parameters into its own structure
  """

  defstruct eth_gap_without_child_blocks: 2,
            gas_price_lowering_factor: 0.9,
            gas_price_raising_factor: 2.0,
            max_gas_price: 20_000_000_000,
            last_block_mined: nil

  @type t() :: %__MODULE__{
          # minimum blocks count where child blocks are not mined therefore gas price needs to be increased
          eth_gap_without_child_blocks: pos_integer(),
          # the factor the gas price will be decreased by
          gas_price_lowering_factor: float(),
          # the factor the gas price will be increased by
          gas_price_raising_factor: float(),
          # maximum gas price above which raising has no effect, limits the gas price calculation
          max_gas_price: pos_integer(),
          # remembers ethereum height and last child block mined, used for the gas price calculation
          last_block_mined: tuple() | nil
        }

  def new(raising_factor, lowering_factor, eth_blocks_gap \\ 2) do
    %__MODULE__{
      gas_price_raising_factor: raising_factor,
      gas_price_lowering_factor: lowering_factor,
      eth_gap_without_child_blocks: eth_blocks_gap,
      last_block_mined: nil
    }
  end

  def with(state, lastchecked_parent_height, lastchecked_mined_child_block_num) do
    %{state | last_block_mined: {lastchecked_parent_height, lastchecked_mined_child_block_num}}
  end
end