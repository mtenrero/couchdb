% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_views_indexer_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch_views/include/couch_views.hrl").
-include_lib("fabric/test/fabric2_test.hrl").

-define(MAP_FUN1, <<"map_fun1">>).
-define(MAP_FUN2, <<"map_fun2">>).
-define(QUERY_SERVER_LANG_BINARY, <<"foo_lang">>).
-define(QUERY_SERVER_LANG_STRING, binary_to_list(?QUERY_SERVER_LANG_BINARY)).

indexer_test_() ->
    {
        "Test view indexing",
        {
            setup,
            fun setup/0,
            fun cleanup/1,
            {
                foreach,
                fun foreach_setup/0,
                fun foreach_teardown/1,
                [
                    ?TDEF_FE(indexed_empty_db),
                    ?TDEF_FE(indexed_single_doc),
                    ?TDEF_FE(updated_docs_are_reindexed),
                    ?TDEF_FE(updated_docs_without_changes_are_reindexed),
                    ?TDEF_FE(deleted_docs_not_indexed),
                    ?TDEF_FE(deleted_docs_are_unindexed),
                    ?TDEF_FE(multiple_docs_with_same_key),
                    ?TDEF_FE(multiple_keys_from_same_doc),
                    ?TDEF_FE(multiple_identical_keys_from_same_doc),
                    ?TDEF_FE(fewer_multiple_identical_keys_from_same_doc),
                    ?TDEF_FE(multiple_design_docs),
                    ?TDEF_FE(multiple_doc_update_with_existing_rows),
                    ?TDEF_FE(handle_size_key_limits),
                    ?TDEF_FE(handle_size_value_limits),
                    ?TDEF_FE(index_autoupdater_callback),
                    ?TDEF_FE(handle_db_recreated_when_running),
                    ?TDEF_FE(handle_db_recreated_after_finished),
                    ?TDEF_FE(handle_doc_updated_when_running),
                    ?TDEF_FE(index_can_recover_from_crash, 60),
                    ?TDEF_FE(handle_acquire_map_context_error)
                ]
            }
        }
    }.

setup() ->
    Ctx = test_util:start_couch([
        fabric,
        couch_jobs,
        js_engine,
        couch_views
    ]),
    Ctx.

cleanup(Ctx) ->
    test_util:stop_couch(Ctx).

foreach_setup() ->
    {ok, Db} = fabric2_db:create(?tempdb(), [{user_ctx, ?ADMIN_USER}]),
    Db.

foreach_teardown(Db) ->
    meck:unload(),
    config:delete("couch_views", "change_limit"),
    ok = fabric2_db:delete(fabric2_db:name(Db), []).

indexed_empty_db(Db) ->
    DDoc = create_ddoc(),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    ?assertEqual({ok, []}, run_query(Db, DDoc, ?MAP_FUN1)).

indexed_single_doc(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"0">>, 0, 0)], Out).

updated_docs_are_reindexed(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"0">>, 0, 0)], Out1),

    Doc2 = Doc1#doc{
        revs = {Pos, [Rev]},
        body = {[{<<"val">>, 1}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2, []),

    {ok, Out2} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"0">>, 1, 1)], Out2),

    % Check that our id index is updated properly
    % as well.
    DbName = fabric2_db:name(Db),
    {ok, Mrst0} = couch_views_util:ddoc_to_mrst(DbName, DDoc),
    fabric2_fdb:transactional(Db, fun(TxDb) ->
        #{tx := Tx} = TxDb,
        Mrst1 = couch_views_trees:open(TxDb, Mrst0),
        IdRow = ebtree:lookup(Tx, Mrst1#mrst.id_btree, <<"0">>),
        ?assertEqual({<<"0">>, [{1, []}, {0, [1]}]}, IdRow)
    end).

updated_docs_without_changes_are_reindexed(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"0">>, 0, 0)], Out1),

    Doc2 = Doc1#doc{
        revs = {Pos, [Rev]},
        body = {[{<<"val">>, 0}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2, []),

    {ok, Out2} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"0">>, 0, 0)], Out2),

    % Check fdb directly to make sure we've also
    % removed the id idx keys properly.
    DbName = fabric2_db:name(Db),
    {ok, Mrst0} = couch_views_util:ddoc_to_mrst(DbName, DDoc),
    fabric2_fdb:transactional(Db, fun(TxDb) ->
        #{tx := Tx} = TxDb,
        Mrst1 = couch_views_trees:open(TxDb, Mrst0),
        IdRow = ebtree:lookup(Tx, Mrst1#mrst.id_btree, <<"0">>),
        ?assertEqual({<<"0">>, [{1, []}, {0, [0]}]}, IdRow)
    end).

deleted_docs_not_indexed(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc1, []),
    Doc2 = Doc1#doc{
        revs = {Pos, [Rev]},
        deleted = true,
        body = {[{<<"val">>, 1}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2, []),

    ?assertEqual({ok, []}, run_query(Db, DDoc, ?MAP_FUN1)).

deleted_docs_are_unindexed(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),
    ?assertEqual([row(<<"0">>, 0, 0)], Out1),

    Doc2 = Doc1#doc{
        revs = {Pos, [Rev]},
        deleted = true,
        body = {[{<<"val">>, 1}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2, []),

    ?assertEqual({ok, []}, run_query(Db, DDoc, ?MAP_FUN1)),

    % Check fdb directly to make sure we've also
    % removed the id idx keys properly.
    DbName = fabric2_db:name(Db),
    {ok, Mrst0} = couch_views_util:ddoc_to_mrst(DbName, DDoc),
    fabric2_fdb:transactional(Db, fun(TxDb) ->
        #{tx := Tx} = TxDb,
        Mrst1 = couch_views_trees:open(TxDb, Mrst0),
        IdRow = ebtree:lookup(Tx, Mrst1#mrst.id_btree, <<"0">>),
        ?assertEqual(false, IdRow)
    end).

multiple_docs_with_same_key(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0, 1),
    Doc2 = doc(1, 1),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_docs(Db, [Doc1, Doc2], []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 1, 1),
            row(<<"1">>, 1, 1)
        ],
        Out
    ).

multiple_keys_from_same_doc(Db) ->
    DDoc = create_ddoc(multi_emit_different),
    Doc = doc(0, 1),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, Doc, []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 1, 1),
            row(<<"0">>, <<"0">>, <<"0">>)
        ],
        Out
    ).

multiple_identical_keys_from_same_doc(Db) ->
    DDoc = create_ddoc(multi_emit_same),
    Doc = doc(0, 1),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, Doc, []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 1, 1),
            row(<<"0">>, 1, 2)
        ],
        Out
    ).

fewer_multiple_identical_keys_from_same_doc(Db) ->
    DDoc = create_ddoc(multi_emit_same),
    Doc0 = #doc{
        id = <<"0">>,
        body = {[{<<"val">>, 1}, {<<"extra">>, 3}]}
    },

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc0, []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 1, 1),
            row(<<"0">>, 1, 2),
            row(<<"0">>, 1, 3)
        ],
        Out1
    ),

    Doc1 = #doc{
        id = <<"0">>,
        revs = {Pos, [Rev]},
        body = {[{<<"val">>, 1}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out2} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 1, 1),
            row(<<"0">>, 1, 2)
        ],
        Out2
    ).

handle_size_key_limits(Db) ->
    ok = meck:new(config, [passthrough]),
    ok = meck:expect(config, get_integer, fun
        ("couch_views", "key_size_limit", _Default) -> 15;
        (_Section, _Key, Default) -> Default
    end),

    DDoc = create_ddoc(multi_emit_key_limit),
    Docs = [doc(1, 2)] ++ [doc(2, 1)],

    {ok, _} = fabric2_db:update_docs(Db, [DDoc | Docs], []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"1">>, 2, 2)], Out),

    {ok, Doc} = fabric2_db:open_doc(Db, <<"2">>),
    Doc2 = Doc#doc{
        body = {[{<<"val">>, 2}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"1">>, 2, 2),
            row(<<"2">>, 2, 2)
        ],
        Out1
    ).

handle_size_value_limits(Db) ->
    ok = meck:new(config, [passthrough]),
    ok = meck:expect(config, get_integer, fun
        ("couch_views", "value_size_limit", _Default) -> 15;
        (_Section, _Key, Default) -> Default
    end),

    DDoc = create_ddoc(multi_emit_key_limit),
    Docs = [doc(1, 2)] ++ [doc(2, 3)],

    {ok, _} = fabric2_db:update_docs(Db, [DDoc | Docs], []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN2),

    ?assertEqual(
        [
            row(<<"1">>, 2, 2),
            row(<<"2">>, 3, 3),
            row(<<"1">>, 22, 2),
            row(<<"2">>, 23, 3)
        ],
        Out
    ),

    {ok, Doc} = fabric2_db:open_doc(Db, <<"1">>),
    Doc2 = Doc#doc{
        body = {[{<<"val">>, 1}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN2),

    ?assertEqual(
        [
            row(<<"2">>, 3, 3),
            row(<<"2">>, 23, 3)
        ],
        Out1
    ).

index_autoupdater_callback(Db) ->
    DDoc = create_ddoc(),
    Doc1 = doc(0),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, Doc1, []),

    DbSeq = fabric2_db:get_update_seq(Db),

    Result = couch_views:build_indices(Db, [DDoc]),
    ?assertMatch([{ok, <<_/binary>>}], Result),
    [{ok, JobId}] = Result,

    ?assertMatch(
        {ok, {_, _}},
        couch_views_jobs:wait_for_job(JobId, DDoc#doc.id, DbSeq)
    ).

multiple_design_docs(Db) ->
    Cleanup = fun() ->
        fabric2_fdb:transactional(Db, fun(TxDb) ->
            DDocs = fabric2_db:get_design_docs(Db),
            ok = couch_views:cleanup_indices(TxDb, DDocs)
        end)
    end,

    DDoc1 = create_ddoc(simple, <<"_design/bar1">>),
    DDoc2 = create_ddoc(simple, <<"_design/bar2">>),

    {ok, _} = fabric2_db:update_doc(Db, doc(0), []),
    {ok, {Pos1, Rev1}} = fabric2_db:update_doc(Db, DDoc1, []),
    ?assertEqual({ok, [row(<<"0">>, 0, 0)]}, run_query(Db, DDoc1, ?MAP_FUN1)),

    % Because run_query/3 can return, and unsubscribe from the job,
    % before it actually finishes, ensure we wait for the job to
    % finish so we get a deterministic setup every time.
    JobId = get_job_id(Db, DDoc1),
    ?assertEqual(ok, wait_job_finished(JobId, 5000)),

    % Add the second ddoc with same view as first one.
    {ok, {Pos2, Rev2}} = fabric2_db:update_doc(Db, DDoc2, []),

    DDoc1Del = DDoc1#doc{revs = {Pos1, [Rev1]}, deleted = true},
    {ok, _} = fabric2_db:update_doc(Db, DDoc1Del, []),

    Cleanup(),

    % Assert that no updates are applied
    meck:new(couch_views_fdb, [passthrough]),
    meck:expect(couch_views_trees, update_views, fun(TxDb, Mrst, Docs) ->
        case Docs of
            [] -> meck:passthrough([TxDb, Mrst, Docs]);
            [_ | _] -> erlang:error(update_triggered)
        end
    end),
    ?assertEqual({ok, [row(<<"0">>, 0, 0)]}, run_query(Db, DDoc2, ?MAP_FUN1)),
    ?assertEqual(ok, wait_job_finished(JobId, 5000)),

    DDoc2Del = DDoc2#doc{revs = {Pos2, [Rev2]}, deleted = true},
    {ok, _} = fabric2_db:update_doc(Db, DDoc2Del, []),

    Cleanup(),

    % After the last ddoc is deleted we should get an error
    ?assertError({ddoc_deleted, _}, run_query(Db, DDoc2, ?MAP_FUN1)).

multiple_doc_update_with_existing_rows(Db) ->
    DDoc = create_ddoc(),
    Doc0 = doc(0),
    Doc1 = doc(1),

    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, {Pos, Rev}} = fabric2_db:update_doc(Db, Doc1, []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual([row(<<"1">>, 1, 1)], Out1),

    Doc2 = Doc1#doc{
        revs = {Pos, [Rev]},
        body = {[{<<"val">>, 2}]}
    },
    {ok, _} = fabric2_db:update_docs(Db, [Doc0, Doc2], []),

    {ok, Out2} = run_query(Db, DDoc, ?MAP_FUN1),

    ?assertEqual(
        [
            row(<<"0">>, 0, 0),
            row(<<"1">>, 2, 2)
        ],
        Out2
    ).

handle_db_recreated_when_running(Db) ->
    DbName = fabric2_db:name(Db),

    DDoc = create_ddoc(),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, doc(0), []),
    {ok, _} = fabric2_db:update_doc(Db, doc(1), []),

    % To intercept job building while it is running ensure updates happen one
    % row at a time.
    config:set("couch_views", "batch_initial_size", "1", false),

    meck_intercept_job_update(self()),

    [{ok, JobId}] = couch_views:build_indices(Db, [DDoc]),

    {Indexer, _Job, _Data} = wait_indexer_update(10000),

    {ok, State} = couch_jobs:get_job_state(undefined, ?INDEX_JOB_TYPE, JobId),
    ?assertEqual(running, State),

    {ok, SubId, running, _} = couch_jobs:subscribe(?INDEX_JOB_TYPE, JobId),

    ok = fabric2_db:delete(DbName, []),
    {ok, Db1} = fabric2_db:create(DbName, [?ADMIN_CTX]),

    Indexer ! continue,

    ?assertMatch(
        {
            ?INDEX_JOB_TYPE,
            JobId,
            finished,
            #{<<"error">> := <<"db_deleted">>}
        },
        couch_jobs:wait(SubId, infinity)
    ),

    {ok, _} = fabric2_db:update_doc(Db1, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db1, doc(2), []),
    {ok, _} = fabric2_db:update_doc(Db1, doc(3), []),

    reset_intercept_job_update(Indexer),

    {ok, Out2} = run_query(Db1, DDoc, ?MAP_FUN1),
    ?assertEqual(
        [
            row(<<"2">>, 2, 2),
            row(<<"3">>, 3, 3)
        ],
        Out2
    ).

handle_db_recreated_after_finished(Db) ->
    DbName = fabric2_db:name(Db),

    DDoc = create_ddoc(),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, doc(0), []),
    {ok, _} = fabric2_db:update_doc(Db, doc(1), []),

    {ok, Out1} = run_query(Db, DDoc, ?MAP_FUN1),
    ?assertEqual(
        [
            row(<<"0">>, 0, 0),
            row(<<"1">>, 1, 1)
        ],
        Out1
    ),

    ok = fabric2_db:delete(DbName, []),

    ?assertError(database_does_not_exist, run_query(Db, DDoc, ?MAP_FUN1)),

    {ok, Db1} = fabric2_db:create(DbName, [?ADMIN_CTX]),

    {ok, _} = fabric2_db:update_doc(Db1, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db1, doc(2), []),
    {ok, _} = fabric2_db:update_doc(Db1, doc(3), []),

    ?assertError(database_does_not_exist, run_query(Db, DDoc, ?MAP_FUN1)),

    {ok, Out2} = run_query(Db1, DDoc, ?MAP_FUN1),
    ?assertEqual(
        [
            row(<<"2">>, 2, 2),
            row(<<"3">>, 3, 3)
        ],
        Out2
    ).

handle_doc_updated_when_running(Db) ->
    DDoc = create_ddoc(),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_doc(Db, doc(0), []),
    {ok, _} = fabric2_db:update_doc(Db, doc(1), []),

    % To intercept job building while it is running ensure updates happen one
    % row at a time.
    config:set("couch_views", "batch_initial_size", "1", false),

    meck_intercept_job_update(self()),

    [{ok, JobId}] = couch_views:build_indices(Db, [DDoc]),

    {Indexer, _Job, _Data} = wait_indexer_update(10000),

    {ok, State} = couch_jobs:get_job_state(undefined, ?INDEX_JOB_TYPE, JobId),
    ?assertEqual(running, State),

    {ok, SubId, running, _} = couch_jobs:subscribe(?INDEX_JOB_TYPE, JobId),

    {ok, Doc} = fabric2_db:open_doc(Db, <<"1">>),
    Doc2 = Doc#doc{
        body = {[{<<"val">>, 2}]}
    },
    {ok, _} = fabric2_db:update_doc(Db, Doc2),

    reset_intercept_job_update(Indexer),
    Indexer ! continue,

    ?assertMatch(
        {
            ?INDEX_JOB_TYPE,
            JobId,
            finished,
            #{<<"active_task_info">> := #{<<"changes_done">> := 1}}
        },
        couch_jobs:wait(SubId, finished, infinity)
    ),

    Args = #mrargs{update = false},
    {ok, Out2} = couch_views:query(
        Db,
        DDoc,
        ?MAP_FUN1,
        fun fold_fun/2,
        [],
        Args
    ),
    ?assertEqual(
        [
            row(<<"0">>, 0, 0)
        ],
        Out2
    ).

index_can_recover_from_crash(Db) ->
    ok = meck:new(config, [passthrough]),
    ok = meck:expect(config, get_integer, fun(Section, Key, Default) ->
        case Section == "couch_views" andalso Key == "change_limit" of
            true -> 1;
            _ -> Default
        end
    end),
    meck:new(couch_eval, [passthrough]),
    meck:expect(couch_eval, map_docs, fun(State, Docs) ->
        Doc = hd(Docs),
        case Doc#doc.id == <<"2">> of
            true ->
                % remove the mock so that next time the doc is processed
                % it will work
                meck:unload(couch_eval),
                throw({fake_crash, test_jobs_restart});
            false ->
                meck:passthrough([State, Docs])
        end
    end),

    DDoc = create_ddoc(),
    Docs = make_docs(3),
    {ok, _} = fabric2_db:update_doc(Db, DDoc, []),
    {ok, _} = fabric2_db:update_docs(Db, Docs, []),

    {ok, Out} = run_query(Db, DDoc, ?MAP_FUN1),
    ?assertEqual(
        [
            row(<<"1">>, 1, 1),
            row(<<"2">>, 2, 2),
            row(<<"3">>, 3, 3)
        ],
        Out
    ).

handle_acquire_map_context_error(_) ->
    meck:new(mock_language_server, [non_strict]),
    config:set(
        "couch_eval.languages",
        ?QUERY_SERVER_LANG_STRING,
        atom_to_list(mock_language_server)
    ),
    meck:expect(mock_language_server, acquire_map_context, fun(_) ->
        {error, foo_error}
    end),
    ?assertError(
        foo_error,
        couch_views_indexer:start_query_server(#mrst{
            db_name = "DbName",
            idx_name = "DDocId",
            language = ?QUERY_SERVER_LANG_BINARY,
            sig = "Sig",
            lib = "Lib",
            views = []
        })
    ).

row(Id, Key, Value) ->
    {row, [
        {id, Id},
        {key, Key},
        {value, Value}
    ]}.

fold_fun({meta, _Meta}, Acc) ->
    {ok, Acc};
fold_fun({row, _} = Row, Acc) ->
    {ok, [Row | Acc]};
fold_fun(complete, Acc) ->
    {ok, lists:reverse(Acc)}.

create_ddoc() ->
    create_ddoc(simple).

create_ddoc(Type) ->
    create_ddoc(Type, <<"_design/bar">>).

create_ddoc(simple, DocId) when is_binary(DocId) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, DocId},
            {<<"views">>,
                {[
                    {?MAP_FUN1,
                        {[
                            {<<"map">>, <<"function(doc) {emit(doc.val, doc.val);}">>}
                        ]}},
                    {?MAP_FUN2,
                        {[
                            {<<"map">>, <<"function(doc) {}">>}
                        ]}}
                ]}}
        ]}
    );
create_ddoc(multi_emit_different, DocId) when is_binary(DocId) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, DocId},
            {<<"views">>,
                {[
                    {?MAP_FUN1,
                        {[
                            {<<"map">>, <<
                                "function(doc) { "
                                "emit(doc._id, doc._id); "
                                "emit(doc.val, doc.val); "
                                "}"
                            >>}
                        ]}},
                    {?MAP_FUN2,
                        {[
                            {<<"map">>, <<"function(doc) {}">>}
                        ]}}
                ]}}
        ]}
    );
create_ddoc(multi_emit_same, DocId) when is_binary(DocId) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, DocId},
            {<<"views">>,
                {[
                    {?MAP_FUN1,
                        {[
                            {<<"map">>, <<
                                "function(doc) { "
                                "emit(doc.val, doc.val * 2); "
                                "emit(doc.val, doc.val); "
                                "if(doc.extra) {"
                                "  emit(doc.val, doc.extra);"
                                "}"
                                "}"
                            >>}
                        ]}},
                    {?MAP_FUN2,
                        {[
                            {<<"map">>, <<"function(doc) {}">>}
                        ]}}
                ]}}
        ]}
    );
create_ddoc(multi_emit_key_limit, DocId) when is_binary(DocId) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, DocId},
            {<<"views">>,
                {[
                    {?MAP_FUN1,
                        {[
                            {<<"map">>, <<
                                "function(doc) { "
                                "if (doc.val === 1) { "
                                "emit('a very long string to be limited', doc.val);"
                                "} else {"
                                "emit(doc.val, doc.val)"
                                "}"
                                "}"
                            >>}
                        ]}},
                    {?MAP_FUN2,
                        {[
                            {<<"map">>, <<
                                "function(doc) { "
                                "emit(doc.val + 20, doc.val);"
                                "if (doc.val === 1) { "
                                "emit(doc.val, 'a very long string to be limited');"
                                "} else {"
                                "emit(doc.val, doc.val)"
                                "}"
                                "}"
                            >>}
                        ]}}
                ]}}
        ]}
    ).

make_docs(Count) ->
    [doc(I) || I <- lists:seq(1, Count)].

doc(Id) ->
    doc(Id, Id).

doc(Id, Val) ->
    couch_doc:from_json_obj(
        {[
            {<<"_id">>, list_to_binary(integer_to_list(Id))},
            {<<"val">>, Val}
        ]}
    ).

run_query(#{} = Db, DDoc, <<_/binary>> = View) ->
    couch_views:query(Db, DDoc, View, fun fold_fun/2, [], #mrargs{}).

get_job_id(#{} = Db, DDoc) ->
    DbName = fabric2_db:name(Db),
    {ok, Mrst} = couch_views_util:ddoc_to_mrst(DbName, DDoc),
    couch_views_jobs:job_id(Db, Mrst).

wait_job_finished(JobId, Timeout) ->
    case couch_jobs:subscribe(?INDEX_JOB_TYPE, JobId) of
        {ok, Sub, _, _} ->
            case couch_jobs:wait(Sub, finished, Timeout) of
                {?INDEX_JOB_TYPE, _, _, _} -> ok;
                timeout -> timeout
            end;
        {ok, finished, _} ->
            ok
    end.

meck_intercept_job_update(ParentPid) ->
    meck:new(couch_jobs, [passthrough]),
    meck:expect(couch_jobs, update, fun(Db, Job, Data) ->
        ParentPid ! {self(), Job, Data},
        receive
            continue -> ok
        end,
        meck:passthrough([Db, Job, Data])
    end).

reset_intercept_job_update(IndexerPid) ->
    meck:expect(couch_jobs, update, fun(Db, Job, Data) ->
        meck:passthrough([Db, Job, Data])
    end),
    IndexerPid ! continue.

wait_indexer_update(Timeout) ->
    receive
        {Pid, Job, Data} when is_pid(Pid) -> {Pid, Job, Data}
    after Timeout ->
        error(timeout_in_wait_indexer_update)
    end.
