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

defmodule OMG.WatcherRPC.Web.View.Block do
  @moduledoc """
  The block view for rendering json
  """

  use OMG.WatcherRPC.Web, :view

  alias OMG.Utils.HttpRPC.Response
  alias OMG.Utils.Paginator
  alias OMG.WatcherRPC.Web.Response, as: WatcherRPCResponse

  def render("block.json", %{response: block}) do
    block
    |> Response.serialize()
    |> WatcherRPCResponse.add_app_infos()
  end

  def render("blocks.json", %{response: %Paginator{data: blocks, data_paging: data_paging}}) do
    blocks
    |> Response.serialize_page(data_paging)
    |> WatcherRPCResponse.add_app_infos()
  end

  def render("validate_block.json", %{response: block}) do
    block
    |> Response.serialize()
    |> WatcherRPCResponse.add_app_infos()
  end
end
