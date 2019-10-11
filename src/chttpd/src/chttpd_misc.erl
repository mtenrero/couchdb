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

-module(chttpd_misc).

-export([
    handle_all_dbs_req/1,
    handle_dbs_info_req/1,
    handle_favicon_req/1,
    handle_favicon_req/2,
    handle_replicate_req/1,
    handle_reload_query_servers_req/1,
    handle_task_status_req/1,
    handle_up_req/1,
    handle_utils_dir_req/1,
    handle_utils_dir_req/2,
    handle_uuids_req/1,
    handle_welcome_req/1,
    handle_welcome_req/2,
    get_stats/0
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-import(chttpd,
    [send_json/2,send_json/3,send_method_not_allowed/2,
    send_chunk/2,start_chunked_response/3]).

-define(MAX_DB_NUM_FOR_DBS_INFO, 100).

% httpd global handlers

handle_welcome_req(Req) ->
    handle_welcome_req(Req, <<"Welcome">>).

handle_welcome_req(#httpd{method='GET'}=Req, WelcomeMessage) ->
    send_json(Req, {[
        {couchdb, WelcomeMessage},
        {version, list_to_binary(couch_server:get_version())},
        {git_sha, list_to_binary(couch_server:get_git_sha())},
        {uuid, couch_server:get_uuid()},
        {features, get_features()}
        ] ++ case config:get("vendor") of
        [] ->
            [];
        Properties ->
            [{vendor, {[{?l2b(K), ?l2b(V)} || {K, V} <- Properties]}}]
        end
    });
handle_welcome_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

get_features() ->
    case clouseau_rpc:connected() of
        true ->
            [search | config:features()];
        false ->
            config:features()
    end.

handle_favicon_req(Req) ->
    handle_favicon_req(Req, get_docroot()).

handle_favicon_req(#httpd{method='GET'}=Req, DocumentRoot) ->
    {DateNow, TimeNow} = calendar:universal_time(),
    DaysNow = calendar:date_to_gregorian_days(DateNow),
    DaysWhenExpires = DaysNow + 365,
    DateWhenExpires = calendar:gregorian_days_to_date(DaysWhenExpires),
    CachingHeaders = [
        %favicon should expire a year from now
        {"Cache-Control", "public, max-age=31536000"},
        {"Expires", couch_util:rfc1123_date({DateWhenExpires, TimeNow})}
    ],
    chttpd:serve_file(Req, "favicon.ico", DocumentRoot, CachingHeaders);
handle_favicon_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

handle_utils_dir_req(Req) ->
    handle_utils_dir_req(Req, get_docroot()).

handle_utils_dir_req(#httpd{method='GET'}=Req, DocumentRoot) ->
    "/" ++ UrlPath = chttpd:path(Req),
    case chttpd:partition(UrlPath) of
    {_ActionKey, "/", RelativePath} ->
        % GET /_utils/path or GET /_utils/
        CachingHeaders = [{"Cache-Control", "private, must-revalidate"}],
        EnableCsp = config:get("csp", "enable", "false"),
        Headers = maybe_add_csp_headers(CachingHeaders, EnableCsp),
        chttpd:serve_file(Req, RelativePath, DocumentRoot, Headers);
    {_ActionKey, "", _RelativePath} ->
        % GET /_utils
        RedirectPath = chttpd:path(Req) ++ "/",
        chttpd:send_redirect(Req, RedirectPath)
    end;
handle_utils_dir_req(Req, _) ->
    send_method_not_allowed(Req, "GET,HEAD").

maybe_add_csp_headers(Headers, "true") ->
    DefaultValues = "default-src 'self'; img-src 'self' data:; font-src 'self'; "
                    "script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline';",
    Value = config:get("csp", "header_value", DefaultValues),
    [{"Content-Security-Policy", Value} | Headers];
maybe_add_csp_headers(Headers, _) ->
    Headers.

handle_all_dbs_req(#httpd{method='GET'}=Req) ->
    Args = couch_mrview_http:parse_params(Req, undefined),
    ShardDbName = config:get("mem3", "shards_db", "_dbs"),
    %% shard_db is not sharded but mem3:shards treats it as an edge case
    %% so it can be pushed thru fabric
    {ok, Info} = fabric:get_db_info(ShardDbName),
    Etag = couch_httpd:make_etag({Info}),
    Options = [{user_ctx, Req#httpd.user_ctx}],
    {ok, Resp} = chttpd:etag_respond(Req, Etag, fun() ->
        {ok, Resp} = chttpd:start_delayed_json_response(Req, 200, [{"ETag",Etag}]),
        VAcc = #vacc{req=Req,resp=Resp},
        fabric:all_docs(ShardDbName, Options, fun all_dbs_callback/2, VAcc, Args)
    end),
    case is_record(Resp, vacc) of
        true -> {ok, Resp#vacc.resp};
        _ -> {ok, Resp}
    end;
handle_all_dbs_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

all_dbs_callback({meta, _Meta}, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "["),
    {ok, Acc#vacc{resp=Resp1}};
all_dbs_callback({row, Row}, #vacc{resp=Resp0}=Acc) ->
    Prepend = couch_mrview_http:prepend_val(Acc),
    case couch_util:get_value(id, Row) of <<"_design", _/binary>> ->
        {ok, Acc};
    DbName ->
        {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, [Prepend, ?JSON_ENCODE(DbName)]),
        {ok, Acc#vacc{prepend=",", resp=Resp1}}
    end;
all_dbs_callback(complete, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_chunk(Resp0, "]"),
    {ok, Resp2} = chttpd:end_delayed_json_response(Resp1),
    {ok, Acc#vacc{resp=Resp2}};
all_dbs_callback({error, Reason}, #vacc{resp=Resp0}=Acc) ->
    {ok, Resp1} = chttpd:send_delayed_error(Resp0, Reason),
    {ok, Acc#vacc{resp=Resp1}}.

handle_dbs_info_req(#httpd{method='POST'}=Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    Props = chttpd:json_body_obj(Req),
    Keys = couch_mrview_util:get_view_keys(Props),
    case Keys of
        undefined -> throw({bad_request, "`keys` member must exist."});
        _ -> ok
    end,
    MaxNumber = config:get_integer("chttpd",
        "max_db_number_for_dbs_info_req", ?MAX_DB_NUM_FOR_DBS_INFO),
    case length(Keys) =< MaxNumber of
        true -> ok;
        false -> throw({bad_request, too_many_keys})
    end,
    {ok, Resp} = chttpd:start_json_response(Req, 200),
    send_chunk(Resp, "["),
    lists:foldl(fun(DbName, AccSeparator) ->
        case catch fabric:get_db_info(DbName) of
            {ok, Result} ->
                Json = ?JSON_ENCODE({[{key, DbName}, {info, {Result}}]}),
                send_chunk(Resp, AccSeparator ++ Json);
            _ ->
                Json = ?JSON_ENCODE({[{key, DbName}, {error, not_found}]}),
                send_chunk(Resp, AccSeparator ++ Json)
        end,
        "," % AccSeparator now has a comma
    end, "", Keys),
    send_chunk(Resp, "]"),
    chttpd:end_json_response(Resp);
handle_dbs_info_req(Req) ->
    send_method_not_allowed(Req, "POST").

handle_task_status_req(#httpd{method='GET'}=Req) ->
    ok = chttpd:verify_is_server_admin(Req),
    {Replies, _BadNodes} = gen_server:multi_call(couch_task_status, all),
    Response = lists:flatmap(fun({Node, Tasks}) ->
        [{[{node,Node} | Task]} || Task <- Tasks]
    end, Replies),
    send_json(Req, lists:sort(Response));
handle_task_status_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

handle_replicate_req(#httpd{method='POST', user_ctx=Ctx} = Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    %% see HACK in chttpd.erl about replication
    PostBody = get(post_body),
    case replicate(PostBody, Ctx) of
        {ok, {continuous, RepId}} ->
            send_json(Req, 202, {[{ok, true}, {<<"_local_id">>, RepId}]});
        {ok, {cancelled, RepId}} ->
            send_json(Req, 200, {[{ok, true}, {<<"_local_id">>, RepId}]});
        {ok, {JsonResults}} ->
            send_json(Req, {[{ok, true} | JsonResults]});
        {ok, stopped} ->
            send_json(Req, 200, {[{ok, stopped}]});
        {error, not_found=Error} ->
            chttpd:send_error(Req, Error);
        {error, {_, _}=Error} ->
            chttpd:send_error(Req, Error);
        {_, _}=Error ->
            chttpd:send_error(Req, Error)
    end;
handle_replicate_req(Req) ->
    send_method_not_allowed(Req, "POST").

replicate({Props} = PostBody, Ctx) ->
    case couch_util:get_value(<<"cancel">>, Props) of
    true ->
        cancel_replication(PostBody, Ctx);
    _ ->
        Node = choose_node([
            couch_util:get_value(<<"source">>, Props),
            couch_util:get_value(<<"target">>, Props)
        ]),
        case rpc:call(Node, couch_replicator, replicate, [PostBody, Ctx]) of
        {badrpc, Reason} ->
            erlang:error(Reason);
        Res ->
            Res
        end
    end.

cancel_replication(PostBody, Ctx) ->
    {Res, _Bad} = rpc:multicall(couch_replicator, replicate, [PostBody, Ctx]),
    case [X || {ok, {cancelled, _}} = X <- Res] of
    [Success|_] ->
        % Report success if at least one node canceled the replication
        Success;
    [] ->
        case lists:usort(Res) of
        [UniqueReply] ->
            % Report a universally agreed-upon reply
            UniqueReply;
        [] ->
            {error, badrpc};
        Else ->
            % Unclear what to do here -- pick the first error?
            % Except try ignoring any {error, not_found} responses
            % because we'll always get two of those
            hd(Else -- [{error, not_found}])
        end
    end.

choose_node(Key) when is_binary(Key) ->
    Checksum = erlang:crc32(Key),
    Nodes = lists:sort([node()|erlang:nodes()]),
    lists:nth(1 + Checksum rem length(Nodes), Nodes);
choose_node(Key) ->
    choose_node(term_to_binary(Key)).

handle_reload_query_servers_req(#httpd{method='POST'}=Req) ->
    chttpd:validate_ctype(Req, "application/json"),
    ok = couch_proc_manager:reload(),
    send_json(Req, 200, {[{ok, true}]});
handle_reload_query_servers_req(Req) ->
    send_method_not_allowed(Req, "POST").

handle_uuids_req(Req) ->
    couch_httpd_misc_handlers:handle_uuids_req(Req).


get_stats() ->
    Other = erlang:memory(system) - lists:sum([X || {_,X} <-
        erlang:memory([atom, code, binary, ets])]),
    Memory = [{other, Other} | erlang:memory([atom, atom_used, processes,
        processes_used, binary, code, ets])],
    {NumberOfGCs, WordsReclaimed, _} = statistics(garbage_collection),
    {{input, Input}, {output, Output}} = statistics(io),
    {CF, CDU} = db_pid_stats(),
    MessageQueues0 = [{couch_file, {CF}}, {couch_db_updater, {CDU}}],
    MessageQueues = MessageQueues0 ++ message_queues(registered()),
    [
        {uptime, couch_app:uptime() div 1000},
        {memory, {Memory}},
        {run_queue, statistics(run_queue)},
        {ets_table_count, length(ets:all())},
        {context_switches, element(1, statistics(context_switches))},
        {reductions, element(1, statistics(reductions))},
        {garbage_collection_count, NumberOfGCs},
        {words_reclaimed, WordsReclaimed},
        {io_input, Input},
        {io_output, Output},
        {os_proc_count, couch_proc_manager:get_proc_count()},
        {stale_proc_count, couch_proc_manager:get_stale_proc_count()},
        {process_count, erlang:system_info(process_count)},
        {process_limit, erlang:system_info(process_limit)},
        {message_queues, {MessageQueues}},
        {internal_replication_jobs, mem3_sync:get_backlog()},
        {distribution, {get_distribution_stats()}}
    ].

db_pid_stats() ->
    {monitors, M} = process_info(whereis(couch_stats_process_tracker), monitors),
    Candidates = [Pid || {process, Pid} <- M],
    CouchFiles = db_pid_stats(couch_file, Candidates),
    CouchDbUpdaters = db_pid_stats(couch_db_updater, Candidates),
    {CouchFiles, CouchDbUpdaters}.

db_pid_stats(Mod, Candidates) ->
    Mailboxes = lists:foldl(
        fun(Pid, Acc) ->
            case process_info(Pid, [message_queue_len, dictionary]) of
                undefined ->
                    Acc;
                PI ->
                    Dictionary = proplists:get_value(dictionary, PI, []),
                    case proplists:get_value('$initial_call', Dictionary) of
                        {Mod, init, 1} ->
                            case proplists:get_value(message_queue_len, PI) of
                                undefined -> Acc;
                                Len -> [Len|Acc]
                            end;
                        _  ->
                            Acc
                    end
            end
        end, [], Candidates
    ),
    format_pid_stats(Mailboxes).

format_pid_stats([]) ->
    [];
format_pid_stats(Mailboxes) ->
    Sorted = lists:sort(Mailboxes),
    Count = length(Sorted),
    [
        {count, Count},
        {min, hd(Sorted)},
        {max, lists:nth(Count, Sorted)},
        {'50', lists:nth(round(Count * 0.5), Sorted)},
        {'90', lists:nth(round(Count * 0.9), Sorted)},
        {'99', lists:nth(round(Count * 0.99), Sorted)}
    ].

get_distribution_stats() ->
    lists:map(fun({Node, Socket}) ->
        {ok, Stats} = inet:getstat(Socket),
        {Node, {Stats}}
    end, erlang:system_info(dist_ctrl)).

handle_up_req(#httpd{method='GET'} = Req) ->
    case config:get("couchdb", "maintenance_mode") of
    "true" ->
        send_json(Req, 404, {[{status, maintenance_mode}]});
    "nolb" ->
        send_json(Req, 404, {[{status, nolb}]});
    _ ->
        {ok, {Status}} = mem3_seeds:get_status(),
        case couch_util:get_value(status, Status) of
            ok ->
                send_json(Req, 200, {Status});
            seeding ->
                send_json(Req, 404, {Status})
        end
    end;

handle_up_req(Req) ->
    send_method_not_allowed(Req, "GET,HEAD").

message_queues(Registered) ->
    lists:map(fun(Name) ->
        Type = message_queue_len,
        {Type, Length} = process_info(whereis(Name), Type),
        {Name, Length}
    end, Registered).

get_docroot() ->
    % if the env var isn’t set, let’s not throw an error, but
    % assume the current working dir is what we want
    os:getenv("COUCHDB_FAUXTON_DOCROOT", "").
