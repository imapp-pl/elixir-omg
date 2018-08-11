# Copyright 2017 OmiseGO Pte Ltd
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

defmodule OmiseGOWatcher.Eventer.Event do
  alias OmiseGO.API.Block
  alias OmiseGO.API.State.Transaction

  @type t ::
          OmiseGOWatcher.Eventer.Event.AddressReceived.t()
          | OmiseGOWatcher.Eventer.Event.InvalidBlock.t()
          | OmiseGOWatcher.Eventer.Event.BlockWithHolding.t()

  defmodule AddressReceived do
    @moduledoc """
    Notifies about received funds by particular address
    """

    def name, do: "address_received"

    defstruct [:tx, :child_blknum, :child_block_hash, :submited_at_ethheight]

    @type t :: %__MODULE__{
            tx: Transaction.Recovered.t(),
            child_blknum: integer(),
            child_block_hash: Block.block_hash_t(),
            submited_at_ethheight: integer()
          }
  end

  defmodule AddressSpent do
    @moduledoc """
    Notifies about spent funds by particular address
    """

    def name, do: "address_spent"

    defstruct [:tx, :child_blknum, :child_block_hash, :submited_at_ethheight]

    @type t :: %__MODULE__{
            tx: Transaction.Recovered.t(),
            child_blknum: integer(),
            child_block_hash: Block.block_hash_t(),
            submited_at_ethheight: integer()
          }
  end

  defmodule InvalidBlock do
    @moduledoc """
    Notifies about invalid block
    """

    def name, do: "invalid_block"

    defstruct [:hash, :number, :error_type]

    @type t :: %__MODULE__{
            hash: Block.block_hash_t(),
            number: integer(),
            error_type: atom()
          }
  end

  defmodule BlockWithHolding do
    @moduledoc """
    Notifies about block-withholding
    """

    def name, do: "block_withholding"

    defstruct [:blknum]

    @type t :: %__MODULE__{
            blknum: pos_integer
          }
  end
end
