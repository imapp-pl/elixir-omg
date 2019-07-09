# Copyright 2019 OmiseGO Pte Ltd
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

defmodule OMG.WatcherRPC.Web.Controller.Transaction do
  @moduledoc """
  Operations related to transaction.
  """

  use OMG.WatcherRPC.Web, :controller

  alias OMG.State.Transaction
  alias OMG.Utils.Metrics
  alias OMG.Watcher.API
  alias OMG.WatcherRPC.Web.Validator

  @doc """
  Retrieves a specific transaction by id.
  """
  def get_transaction(conn, params) do
    with {:ok, id} <- expect(params, "id", :hash) do
      id
      |> API.Transaction.get()
      |> api_response(conn, :transaction)
    end
  end

  @doc """
  Retrieves a list of transactions
  """
  def get_transactions(conn, params) do
    with {:ok, constraints} <- Validator.Constraints.parse(params) do
      API.Transaction.get_transactions(constraints)
      |> api_response(conn, :transactions)
    end
  end

  @doc """
  Submits transaction to child chain
  """
  def submit(conn, params) do
    with {:ok, txbytes} <- expect(params, "transaction", :hex) do
      submit_tx(txbytes, conn)
    end
    |> increment_metrics_counter()
  end

  @doc """
  Thin-client version of `/transaction.submit` that accepts json encoded transaction
  """
  def submit_typed(conn, params) do
    with {:ok, signed_tx} <- Validator.TypedDataSigned.parse(params) do
      # it's tempting to skip the unnecessary encoding-decoding part, but it gain broader
      # validation and communicates with API layer with known structures than bytes
      signed_tx
      |> Transaction.Signed.encode()
      |> submit_tx(conn)
    end
    |> increment_metrics_counter()
  end

  @doc """
  Given token, amount and spender, finds spender's inputs sufficient to perform a payment.
  If also provided with receiver's address, creates and encodes a transaction.
  """
  def create(conn, params) do
    with {:ok, order} <- Validator.Order.parse(params) do
      API.Transaction.create(order)
      |> API.Transaction.include_typed_data()
      |> api_response(conn, :create)
    end
  end

  # Provides extra validation (recover_from) and passes transaction to API layer
  defp submit_tx(txbytes, conn) do
    with {:ok, %Transaction.Recovered{signed_tx: signed_tx}} <- Transaction.Recovered.recover_from(txbytes) do
      API.Transaction.submit(signed_tx)
      |> api_response(conn, :submission)
    end
  end

  defp increment_metrics_counter(response) do
    case response do
      {:error, {:validation_error, _, _}} ->
        Metrics.increment("transaction.failed.validation", 1)

      %Plug.Conn{} ->
        Metrics.increment("transaction.succeed", 1)

      _ ->
        Metrics.increment("transaction.failed.unidentified", 1)
    end

    response
  end
end
