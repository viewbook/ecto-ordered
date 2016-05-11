defmodule EctoOrdered do
  @moduledoc """
  EctoOrdered provides changeset methods for updating ordering an ordering column

  It should be added to your schema like so:

  ```
  defmodule OrderedListItem do
    use Ecto.Schema
    import Ecto.Changeset

    schema "ordered_list_item" do
      field :title,            :string
      field :position,         :integer
    end

    def changeset(model, params) do
      model
      |> cast(params, [:position, :title])
      |> set_order(:position)
    end

    def delete(model) do
      model
      |> cast(%{}, [])
      |> Map.put(:action, :delete)
      |> set_order(:position)
    end
  end
  ```

  Note the `delete` function used to ensure that the remaining items are repositioned on
  deletion.

  """

  @max 8388607
  @min -8388607

  defstruct repo:         nil,
            module:       nil,
            position_field:        :position,
            rank_field: :rank,
            scope_field:        nil,
            current_last: nil,
            current_first: nil

  defmodule InvalidMove do
    defexception type: nil
    def message(%__MODULE__{type: :too_large}), do: "too large"
    def message(%__MODULE__{type: :too_small}), do: "too small"
  end

  import Ecto.Query
  import Ecto.Changeset
  alias EctoOrdered, as: Order

  @doc """
  Returns a changeset which will include updates to the other ordered rows
  within the same transaction as the insertion, deletion or update of this row.

  The arguments are as follows:
  - `changeset` the changeset which is part of the ordered list
  - `field` the field in which the order should be stored
  - `scope` the field in which the scope for the order should be stored (optional)
  """
  def set_order(changeset, position_field, rank_field, scope_field \\ nil) do
    changeset
    |> prepare_changes( fn changeset ->
      case changeset.action do
        :insert -> EctoOrdered.before_insert changeset, position_field, rank_field, scope_field
        :update -> EctoOrdered.before_update changeset, position_field, rank_field, scope_field
      end
    end)
  end

  @doc false
  def before_insert(cs, position_field, rank_field, scope_field) do
    struct = %Order{module: cs.data.__struct__,
                    position_field: position_field,
                    rank_field: rank_field,
                    scope_field: scope_field,
                    repo: cs.repo
                   }

    if get_field(cs, position_field) do
      update_rank(struct, cs)
    else
      update_rank(struct, put_change(cs, position_field, :last))
    end |> ensure_unique_position(struct)
  end

  @doc false
  def before_update(cs, position_field, rank_field, scope_field \\ nil) do
    struct = %Order{module: cs.data.__struct__,
                    position_field: position_field,
                    rank_field: rank_field,
                    scope_field: scope_field,
                    repo: cs.repo
                   }
    case fetch_change(cs, position_field) do
      {:ok, _} -> update_rank(struct, cs) |> ensure_unique_position(struct)
      :error -> cs
    end
  end

  defp update_rank(%Order{rank_field: rank_field, position_field: position_field} = struct, cs) do
    case get_field(cs, position_field) do
      :last -> %Order{current_last: current_last} = update_current_last(struct, cs)
        if current_last do
          put_change(cs, rank_field, rank_between(@max, current_last))
        else
          update_rank(struct, put_change(cs, position_field, :middle))
        end
      :middle -> put_change(cs, rank_field, rank_between(@max, @min))
      nil -> update_rank(struct, put_change(cs, position_field, :last))
      position when is_integer(position) ->
        {rank_before, rank_after} = neighbours_at_position(struct, position, cs)
        put_change(cs, rank_field, rank_between(rank_after, rank_before))
    end
  end

  defp ensure_unique_position(cs, %Order{rank_field: rank_field} = struct) do
    rank = get_field(cs, rank_field)
    if rank > @max || current_at_rank(struct, cs) do
      shift_ranks(struct, cs)
    end
    cs
  end

  defp shift_ranks(%Order{module: module, rank_field: rank_field} = struct, cs) do
    query = scope_query(module, struct, cs)
    current_rank = get_field(cs, rank_field)
    %Order{current_first: current_first} = update_current_first(struct, cs)
    %Order{current_last: current_last} = update_current_last(struct, cs)
    cond do
      current_first > @min && current_rank == @max -> shift_others_down(struct, cs)
      current_last < @max - 1 && current_rank < current_last -> shift_others_up(struct, cs)
      true -> rebalance_ranks(struct, cs)
    end
  end

  defp rebalance_ranks(%Order{module: module,
                              repo: repo,
                              rank_field: rank_field,
                              position_field: position_field
                             } = struct, cs) do
    rows = current_order(struct, cs)
    old_attempted_rank = get_field(cs, rank_field)
    count = length(rows) + 1

    rows
    |> Enum.with_index
    |> Enum.map(fn {row, index} ->
      old_rank = Map.get(row, rank_field)
      change(row, [{rank_field,  rank_for_row(old_rank, index, count, old_attempted_rank)}])
      |> repo.update!
    end)
    put_change(cs, rank_field, rank_for_row(0, get_field(cs, position_field), count, 1))
  end

  defp rank_for_row(old_rank, index, count, old_attempted_rank) do
    # If our old rank is less than the old attempted rank, then our effective index is fine
    new_index = if old_rank < old_attempted_rank do
      index
    # otherwise, we need to increment our index by 1 
    else
      index + 1
    end
    round((@max - @min) / count) * new_index + @min
  end

  defp current_order(%Order{module: module, rank_field: rank_field, repo: repo} = struct, cs) do
    (from m in module, order_by: field(m, ^rank_field))
     |> scope_query(struct, cs)
     |> repo.all
  end

  defp shift_others_up(%Order{module: module,
                                rank_field: rank_field,
                                repo: repo} = struct, %{model: existing} = cs) do
    current_rank = get_field(cs, rank_field)
    (from m in module, where: field(m, ^rank_field) >= ^current_rank)
    |> exclude_existing(existing)
    |> repo.update_all([inc: [{rank_field, 1}]])
    cs
  end

  defp shift_others_down(%Order{module: module,
                                rank_field: rank_field,
                                repo: repo} = struct, %{model: existing} = cs) do
    current_rank = get_field(cs, rank_field)
    (from m in module, where: field(m, ^rank_field) <= ^current_rank)
    |> exclude_existing(existing)
    |> repo.update_all([inc: [{rank_field, -1}]])
    cs
  end

  defp current_at_rank(%Order{module: module, repo: repo, rank_field: rank_field} = struct, cs) do
    rank = get_field(cs, rank_field)
    (from m in module, where: field(m, ^rank_field) == ^rank, limit: 1)
    |> scope_query(struct, cs)
    |> repo.one
  end

  defp neighbours_at_position(%Order{module: module,
                                     rank_field: rank_field,
                                     repo: repo
                                    } = struct, position, cs) when position <= 0 do
    first = (from m in module,
             select: field(m, ^rank_field),
             order_by: [asc: field(m, ^rank_field)],
             limit: 1
    ) |> scope_query(struct, cs) |> repo.one

    if first do
      {@min, first}
    else
      {@min, @max}
    end
  end

  defp neighbours_at_position(%Order{module: module,
                                     rank_field: rank_field,
                                     repo: repo
                          } = struct, position, %{data: existing} = cs) do
    %Order{current_last: current_last} = update_current_last(struct, cs)
    neighbours = (from m in module,
     select: field(m, ^rank_field),
     order_by: [asc: field(m, ^rank_field)],
     limit: 2,
     offset: ^(position - 1)
    )
    |> scope_query(struct, cs)
    |> exclude_existing(existing)
    |> repo.all
    case neighbours do
      [] -> {current_last, @max}
      [bef] -> {bef, @max}
      [bef, aft] -> {bef, aft}
    end
  end

  defp exclude_existing(query, %{id: nil}) do
    query
  end

  defp exclude_existing(query, existing) do
    from r in query, where: r.id != ^existing.id
  end

  defp update_current_last(%Order{current_last: nil,
                                module: module,
                                rank_field: rank_field,
                                repo: repo,
                                scope_field: scope_field
                               } = struct, cs) do
    last = (from m in module,
            select: field(m, ^rank_field),
            order_by: [desc: field(m, ^rank_field)],
            limit: 1
    )
    |> scope_query(struct, cs)
    |> repo.one
    if last do
      %Order{struct | current_last: last}
    else
      %Order{struct | current_last: @min}
    end
  end

  defp update_current_last(%Order{} = struct, _) do
    # noop. We've already got the last.
    struct
  end

  defp update_current_first(%Order{current_first: nil,
                                  module: module,
                                  rank_field: rank_field,
                                  repo: repo
                                 } = struct, cs) do
    first = (from m in module,
            select: field(m, ^rank_field),
            order_by: [asc: field(m, ^rank_field)],
            limit: 1
    )
    |> scope_query(struct, cs)
    |> repo.one

    if first do
      %Order{struct | current_first: first}
    else
      struct
    end
  end


  defp rank_between(nil, nil) do
    rank_between(8388607, -8388607)
  end

  defp rank_between(above, below) do
    ( above - below ) / 2
    |> round
    |> + below
  end

  defp scope_query(query, %Order{scope_field: scope_field}, cs) do
    scope = get_field(cs, scope_field)
    if scope do
      (from q in query, where: field(q, ^scope_field) == ^scope)
    else
      query
    end
  end

end
