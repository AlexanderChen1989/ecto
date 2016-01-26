defmodule Ecto.Repo.Preloader do
  # The module invoked by user defined repos
  # for preload related functionality.
  @moduledoc false

  require Ecto.Query

  @doc """
  Transforms a result set based on query preloads, loading
  the associations onto their parent model.
  """
  @spec query([list], Ecto.Repo.t, list, list, fun, Keyword.t) :: [list]
  def query([], _repo, _preloads, _assocs, _fun, _opts), do: []
  def query(rows, _repo, [], _assocs, fun, _opts), do: Enum.map(rows, fun)

  def query(rows, repo, preloads, assocs, fun, opts) do
    rows
    |> extract
    |> do_preload(repo, preloads, assocs, opts)
    |> unextract(rows, fun)
  end

  defp extract([[nil|_]|t2]), do: extract(t2)
  defp extract([[h|_]|t2]),   do: [h|extract(t2)]
  defp extract([]),           do: []

  defp unextract(structs, [[nil|_]=h2|t2], fun),  do: [fun.(h2)|unextract(structs, t2, fun)]
  defp unextract([h1|structs], [[_|t1]|t2], fun), do: [fun.([h1|t1])|unextract(structs, t2, fun)]
  defp unextract([], [], _fun),                   do: []

  @doc """
  Implementation for `Ecto.Repo.preload/2`.
  """
  @spec preload(structs, atom, atom | list, Keyword.t) ::
                structs when structs: [Ecto.Schema.t] | Ecto.Schema.t
  def preload(structs, repo, preloads, opts) when is_list(structs) do
    do_preload(structs, repo, preloads, nil, opts)
  end

  def preload(struct, repo, preloads, opts) when is_map(struct) do
    do_preload([struct], repo, preloads, nil, opts) |> hd()
  end

  defp do_preload(structs, repo, preloads, assocs, opts) do
    preloads = normalize(preloads, assocs, preloads)
    preload_each(structs, repo, preloads, opts)
  rescue
    e ->
      # Reraise errors so we ignore the preload inner stacktrace
      reraise e
  end

  ## Preloading

  defp preload_each(structs, _repo, [], _opts),   do: structs
  defp preload_each([], _repo, _preloads, _opts), do: []
  defp preload_each([sample|_] = structs, repo, preloads, opts) do
    module      = sample.__struct__
    {prefix, _} = sample.__meta__.source
    preloads    = expand(module, preloads, [])

    entries =
      Enum.map preloads, fn
        {_, {:assoc, assoc, related_key}, sub_preloads} ->
          preload_assoc(structs, module, repo, prefix, assoc, related_key, sub_preloads, opts)
        {_, {:through, _, _} = info, {nil, []}} ->
          info
      end

    for struct <- structs do
      Enum.reduce entries, struct, &load/2
    end
  end

  ## Association preloading

  defp preload_assoc(structs, module, repo, prefix,
                     %{cardinality: card} = assoc, related_key, {query, preloads}, opts) do
    {fetch_ids, loaded_ids, loaded_structs} =
      fetch_ids(structs, module, assoc, opts)
    {fetch_ids, fetch_structs} =
      fetch_query(fetch_ids, assoc, repo, query, prefix, related_key, opts)

    all = preload_each(loaded_structs ++ fetch_structs, repo, preloads, opts)
    {:assoc, assoc, assoc_map(card, loaded_ids ++ fetch_ids, all)}
  end

  defp fetch_ids(structs, module, assoc, opts) do
    %{field: field, owner_key: owner_key, cardinality: card} = assoc
    force? = Keyword.get(opts, :force, false)

    Enum.reduce structs, {[], [], []}, fn struct, {fetch_ids, loaded_ids, loaded_structs} ->
      assert_struct!(module, struct)
      %{^owner_key => id, ^field => value} = struct

      cond do
        is_nil(id) ->
          {fetch_ids, loaded_ids, loaded_structs}
        force? or not Ecto.assoc_loaded?(value) ->
          {[id|fetch_ids], loaded_ids, loaded_structs}
        card == :one ->
          {fetch_ids, [id|loaded_ids], [value|loaded_structs]}
        card == :many ->
          {fetch_ids,
           List.duplicate(id, length(value)) ++ loaded_ids,
           value ++ loaded_structs}
      end
    end
  end

  defp fetch_query([], _assoc, _repo, _query, _prefix, _related_key) do
    {[], []}
  end

  defp fetch_query(ids, %{cardinality: card} = assoc, repo, query, prefix, related_key, opts) do
    query = assoc.__struct__.assoc_query(assoc, query, Enum.uniq(ids))
    field = related_key_to_field(query, related_key)

    # Normalize query
    query = %{ensure_select(query) | prefix: prefix}

    # Add the related key to the query results
    query = update_in query.select.expr, &{:{}, [], [field, &1]}

    # If we are returning many results, we must sort by the key too
    query =
      case card do
        :many ->
          update_in query.order_bys, fn order_bys ->
            [%Ecto.Query.QueryExpr{expr: [asc: field], params: [],
                                   file: __ENV__.file, line: __ENV__.line}|order_bys]
          end
        :one ->
          query
      end

    unzip_ids repo.all(query, opts), [], []
  end

  defp ensure_select(%{select: nil} = query) do
    select = %Ecto.Query.SelectExpr{expr: {:&, [], [0]}, line: __ENV__.line, file: __ENV__.file}
    %{query | select: select}
  end
  defp ensure_select(query) do
    query
  end

  defp related_key_to_field(query, {pos, key}) do
    {{:., [], [{:&, [], [related_key_pos(query, pos)]}, key]}, [], []}
  end

  defp related_key_pos(_query, pos) when pos >= 0, do: pos
  defp related_key_pos(query, pos), do: Ecto.Query.Builder.count_binds(query) + pos

  defp unzip_ids([{k, v}|t], acc1, acc2), do: unzip_ids(t, [k|acc1], [v|acc2])
  defp unzip_ids([], acc1, acc2), do: {acc1, acc2}

  defp assert_struct!(mod, %{__struct__: mod}), do: true
  defp assert_struct!(mod, %{__struct__: struct}) do
    raise ArgumentError, "expected a homogeneous list containing the same struct, " <>
                         "got: #{inspect mod} and #{inspect struct}"
  end

  defp assoc_map(:one, ids, structs) do
    one_assoc_map(ids, structs, %{})
  end
  defp assoc_map(:many, ids, structs) do
    many_assoc_map(ids, structs, %{})
  end

  defp one_assoc_map([id|ids], [struct|structs], map) do
    one_assoc_map(ids, structs, Map.put(map, id, struct))
  end
  defp one_assoc_map([], [], map) do
    map
  end

  defp many_assoc_map([id|ids], [struct|structs], map) do
    {ids, structs, acc} = split_while(ids, structs, id, [struct])
    many_assoc_map(ids, structs, Map.put(map, id, acc))
  end
  defp many_assoc_map([], [], map) do
    map
  end

  defp split_while([id|ids], [struct|structs], id, acc),
    do: split_while(ids, structs, id, [struct|acc])
  defp split_while(ids, structs, _id, acc),
    do: {ids, structs, acc}

  ## Load preloaded data

  defp load({:assoc, assoc, ids}, struct) do
    %{field: field, owner_key: owner_key, cardinality: cardinality} = assoc
    key = Map.fetch!(struct, owner_key)

    loaded =
      case ids do
        %{^key => value} -> value
        _ when cardinality == :many -> []
        _ -> nil
      end

    Map.put(struct, field, loaded)
  end

  defp load({:through, %{cardinality: cardinality} = assoc, [h|t]}, struct) do
    initial = struct |> Map.fetch!(h) |> List.wrap
    loaded  = Enum.reduce(t, initial, &recur_through/2)

    if cardinality == :one do
      loaded = List.first(loaded)
    end

    Map.put(struct, assoc.field, loaded)
  end

  defp recur_through(assoc, structs) do
    Enum.reduce(structs, {[], %{}}, fn struct, acc ->
      children = struct |> Map.fetch!(assoc) |> List.wrap

      Enum.reduce children, acc, fn child, {fresh, set} ->
        [{_, pk}] = Ecto.primary_key!(child)
        pk || raise Ecto.NoPrimaryKeyValueError, struct: child

        case set do
          %{^pk => true} ->
            {fresh, set}
          _ ->
            {[child|fresh], Map.put(set, pk, true)}
        end
      end
    end) |> elem(0) |> Enum.reverse()
  end

  ## Normalizer

  def normalize(preload, assocs, original) do
    normalize_each(wrap(preload, original), [], assocs, original)
  end

  defp normalize_each({atom, {%Ecto.Query{} = query, list}}, acc, assocs, original) when is_atom(atom) do
    no_assoc!(assocs, atom)
    [{atom, {query, normalize_each(wrap(list, original), [], nil, original)}}|acc]
  end

  defp normalize_each({atom, %Ecto.Query{} = query}, acc, assocs, _original) when is_atom(atom) do
    no_assoc!(assocs, atom)
    [{atom, {query, []}}|acc]
  end

  defp normalize_each({atom, list}, acc, assocs, original) when is_atom(atom) do
    no_assoc!(assocs, atom)
    [{atom, {nil, normalize_each(wrap(list, original), [], nil, original)}}|acc]
  end

  defp normalize_each(atom, acc, assocs, _original) when is_atom(atom) do
    no_assoc!(assocs, atom)
    [{atom, {nil, []}}|acc]
  end

  defp normalize_each(other, acc, assocs, original) do
    Enum.reduce(wrap(other, original), acc, &normalize_each(&1, &2, assocs, original))
  end

  defp wrap(list, _original) when is_list(list),
    do: list
  defp wrap(atom, _original) when is_atom(atom),
    do: atom
  defp wrap(other, original) do
    raise ArgumentError, "invalid preload `#{inspect other}` in `#{inspect original}`. " <>
                         "preload expects an atom, a (nested) keyword or a (nested) list of atoms"
  end

  defp no_assoc!(nil, _atom), do: nil
  defp no_assoc!(assocs, atom) do
    if assocs[atom] do
      raise ArgumentError, "cannot preload association `#{inspect atom}` because " <>
                           "it has already been loaded with join association"
    end
  end

  ## Expand

  def expand(model, preloads, acc) do
    Enum.reduce(preloads, acc, fn {preload, sub_preloads}, acc ->
      case List.keyfind(acc, preload, 0) do
        {^preload, info, extra_preloads} ->
          List.keyreplace(acc, preload, 0,
                          {preload, info, merge_preloads(preload, sub_preloads, extra_preloads)})
        nil ->
          assoc = Ecto.Association.association_from_schema!(model, preload)
          info  = assoc.__struct__.preload_info(assoc)

          case info do
            {:assoc, _, _} ->
              [{preload, info, sub_preloads}|acc]
            {:through, _, through} ->
              through =
                through
                |> Enum.reverse
                |> Enum.reduce(sub_preloads, &{nil, [{&1, &2}]})
                |> elem(1)
              List.keystore(expand(model, through, acc), preload, 0, {preload, info, {nil, []}})
          end
      end
    end)
  end

  defp merge_preloads(_preload, {nil, left}, {query, right}),
    do: {query, left ++ right}
  defp merge_preloads(_preload, {query, left}, {nil, right}),
    do: {query, left ++ right}
  defp merge_preloads(preload, {left, _}, {right, _}) do
    raise ArgumentError, "cannot preload `#{preload}` as it has been supplied more than once " <>
                         "with different queries: #{inspect left} and #{inspect right}"
  end

  defp reraise(exception) do
    reraise exception, Enum.reject(System.stacktrace, &match?({__MODULE__, _, _, _}, &1))
  end
end
