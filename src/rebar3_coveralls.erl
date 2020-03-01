%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Copyright (c) 2013-2016, Markus Ekholm
%%% All rights reserved.
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%    * Redistributions of source code must retain the above copyright
%%%      notice, this list of conditions and the following disclaimer.
%%%    * Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%    * Neither the name of the <organization> nor the
%%%      names of its contributors may be used to endorse or promote products
%%%      derived from this software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL MARKUS EKHOLM BE LIABLE FOR ANY
%%% DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%%
%%% @copyright 2013-2016 (c) Yury Gargay <yury.gargay@gmail.com>,
%%% Markus Ekholm <markus@botten.org>
%%% @end
%%% @author Yury Gargay <yury.gargay@gmail.com>
%%% @author Markus Ekholm <markus@botten.org>
%%% @doc coveralls plugin for rebar3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(rebar3_coveralls).
-behaviour(provider).

-export([ init/1
        , do/1
        , format_error/1
        ]).

-define(PROVIDER, send).
-define(DEPS, [{default, app_discovery}]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
  Provider = providers:create([ {name,       ?PROVIDER}
                              , {module,     ?MODULE}
                              , {namespace,  coveralls}
                              , {bare,       true}
                              , {deps,       ?DEPS}
                              , {example,    "rebar3 coveralls send"}
                              , {short_desc, "Send coverdata to coveralls."}
                              , {desc,       "Send coveralls to coveralls."}
                              , {opts,       []}
                              ]),
  {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
  rebar_api:info("Running coveralls...", []),
  ConvertAndSend = fun coveralls:convert_and_send_file/2,
  Get            = fun(Key, Def) -> rebar_state:get(State, Key, Def) end,
  GetLocal       = fun(Key, Def) -> rebar_state:get(State, Key, Def) end,
  MaybeSkip      = fun() -> ok end,
  ok = cover_paths(State),
  try
    do_coveralls(ConvertAndSend,
                 Get,
                 GetLocal,
                 MaybeSkip,
                 'send-coveralls'),
    {ok, State}
  catch throw:{error, {ErrCode, Msg}} ->
      io:format("Failed sending coverdata to coveralls, ~p: ~p",
                [ErrCode, Msg]),
      {error, rebar_abort}
  end.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
  io_lib:format("~p", [Reason]).

cover_paths(State) ->
  lists:foreach(fun(App) ->
                    AppDir = rebar_app_info:out_dir(App),
                    true   = code:add_patha(filename:join([AppDir, "ebin"])),
                    _      = code:add_patha(filename:join([AppDir, "test"]))
                end,
                rebar_state:project_apps(State)),
  _ = code:add_patha(filename:join([rebar_dir:base_dir(State), "test"])),
  ok.

%%=============================================================================
%% Internal functions

to_binary(List) when is_list(List) ->
  unicode:characters_to_binary(List, utf8, utf8);
to_binary(Atom) when is_atom(Atom) ->
  atom_to_binary(Atom, utf8);
to_binary(Bin) when is_binary(Bin) ->
  Bin.
to_boolean(true) -> true;
to_boolean(1)    -> true;
to_boolean(_)    -> false.

do_coveralls(ConvertAndSend, Get, GetLocal, MaybeSkip, Task) ->
  File         = GetLocal(coveralls_coverdata, undef),
  ServiceName  = to_binary(GetLocal(coveralls_service_name, undef)),
  ServiceJobId = to_binary(GetLocal(coveralls_service_job_id, undef)),
  F            = fun(X) -> X =:= undef orelse X =:= false end,
  CoverExport  = Get(cover_export_enabled, false),
  case lists:any(F, [File, ServiceName, ServiceJobId, CoverExport]) of
    true  ->
      throw({error,
             "need to specify coveralls_* and cover_export_enabled "
             "in rebar.config"});
    false ->
      ok
  end,

  Report0 =
    #{service_job_id => ServiceJobId,
      service_name => ServiceName,
      run_at => format_iso8601(calendar:universal_time())},
  Report1 = case GetLocal(coveralls_attach_git_info, false) of
    true ->
      maps:put(git, git_info(), Report0);
    false ->
      Report0
  end,

  Opts = [{coveralls_repo_token,           repo_token,           string},
          {coveralls_service_pull_request, service_pull_request, string},
          {coveralls_parallel,             parallel,             boolean}],
  Report =
    lists:foldl(fun({Cfg, Key, Conv}, R) ->
                    case GetLocal(Cfg, undef) of
                      undef -> R;
                      Value when Conv =:= string  -> maps:put(Key, to_binary(Value), R);
                      Value when Conv =:= boolean -> maps:put(Key, to_boolean(Value), R);
                      Value -> maps:put(Key, Value, R)
                    end
                end, Report1, Opts),

  DoCoveralls = (GetLocal(do_coveralls_after_ct, true) andalso Task == ct)
    orelse (GetLocal(do_coveralls_after_eunit, true) andalso Task == eunit)
    orelse Task == 'send-coveralls',
  case DoCoveralls of
    true ->
      io:format("rebar_coveralls:"
                "Exporting cover data "
                "from ~s using service ~s and jobid ~s~n",
                [File, ServiceName, ServiceJobId]),
      ok = ConvertAndSend(File, Report);
    _ -> MaybeSkip()
  end.

format_iso8601({{Y,Mo,D}, {H,Mn,S}}) ->
  FmtStr = "~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0BZ",
  IsoStr = io_lib:format(FmtStr, [Y, Mo, D, H, Mn, S]),
  list_to_binary(IsoStr).

git_info() ->
  Port = open_port({spawn, "git rev-parse HEAD"}, [stderr_to_stdout, exit_status]),
  Head = receive
    {Port, {data, Data}} -> Data
  end,
  receive
    {Port, {exit_status, 0}} ->
      git_info(list_to_binary(string:chomp(Head)));
    {Port, _} ->
      undef
  end.

git_info(CommitSha) ->
  Branch = os_cmd("git rev-parse --abbrev-ref HEAD"),
  AuthorName = os_cmd(<<"git show --no-patch --format=\"%an\" ", CommitSha/binary, " | head">>),
  AuthorEmail = os_cmd(<<"git show --no-patch --format=\"%ae\" ", CommitSha/binary, " | head">>),
  CommitterName = os_cmd(<<"git show --no-patch --format=\"%cn\" ", CommitSha/binary, " | head">>),
  CommitterEmail = os_cmd(<<"git show --no-patch --format=\"%ce\" ", CommitSha/binary, " | head">>),
  Message = os_cmd(<<"git show --no-patch --format=\"%s\" ", CommitSha/binary, " | head">>),
  #{
    head => #{
      id => CommitSha,
      author_name => AuthorName,
      author_email => AuthorEmail,
      committer_name => CommitterName,
      committer_email => CommitterEmail,
      message => Message
    },
    branch => Branch,
    remotes => parse_git_remote(os_cmd("git remote -v"))
  }.

os_cmd(Cmd) when is_binary(Cmd) ->
  os_cmd(binary_to_list(Cmd));
os_cmd(Cmd) ->
  list_to_binary(string:chomp(os:cmd(Cmd))).

parse_git_remote(Data) ->
  List = lists:foldl(fun(Line, Acc) ->
    [Name, Url | _] = re:split(Line, "[\s\t]+"),
    case lists:keyfind(Name, 1, Acc) of
      false ->
        [{Name, Url} | Acc];
      _ ->
        Acc
    end
  end, [], string:split(Data, "\n")),
  [#{name => Name, url => Url} || {Name, Url} <- List].

%%=============================================================================
%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

task_test_() ->
  File           = "foo",
  ServiceJobId   = "123",
  ServiceName    = "bar",
  ConvertAndSend = fun("foo", #{service_job_id := <<"123">>,
                                service_name := <<"bar">>}) -> ok end,
  ConvertWithOpts = fun("foo", #{service_job_id       := <<"123">>,
                                 service_name         := <<"bar">>,
                                 service_pull_request := <<"PR#1">>,
                                 parallel             := true}) -> ok
                    end,
  Get            = fun(cover_export_enabled, _) -> true end,
  GetLocal       = fun(coveralls_coverdata, _)      -> File;
                      (coveralls_service_name, _)   -> ServiceName;
                      (coveralls_service_job_id, _) -> ServiceJobId;
                      (do_coveralls_after_eunit, _) -> true;
                      (do_coveralls_after_ct, _)    -> true;
                      (coveralls_repo_token, _)     -> [];
                      (_, Default)                  -> Default
                   end,
  GetLocalAllOpt = fun(coveralls_coverdata, _)      -> File;
                      (coveralls_service_name, _)   -> ServiceName;
                      (coveralls_service_job_id, _) -> ServiceJobId;
                      (coveralls_service_pull_request, _) -> "PR#1";
                      (coveralls_parallel, _)       -> true;
                      (do_coveralls_after_eunit, _) -> true;
                      (do_coveralls_after_ct, _)    -> true;
                      (coveralls_repo_token, _)     -> [];
                      (_, Default)                  -> Default
                   end,
  GetLocalWithCoverallsTask
                 = fun(coveralls_coverdata, _)      -> File;
                      (coveralls_service_name, _)   -> ServiceName;
                      (coveralls_service_job_id, _) -> ServiceJobId;
                      (do_coveralls_after_eunit, _) -> false;
                      (do_coveralls_after_ct, _)    -> false;
                      (coveralls_repo_token, _)     -> [];
                      (_, Default)                  -> Default
                   end,
  GetBroken     = fun(cover_export_enabled, _) -> false end,
  MaybeSkip     = fun() -> skip end,
  [ ?_assertEqual(ok, do_coveralls(ConvertAndSend, Get, GetLocal, MaybeSkip, eunit))
  , ?_assertEqual(ok, do_coveralls(ConvertAndSend, Get, GetLocal, MaybeSkip, ct))
  , ?_assertThrow({error, _}, do_coveralls(ConvertAndSend, GetBroken, GetLocal, MaybeSkip, eunit))
  , ?_assertThrow({error, _}, do_coveralls(ConvertAndSend, GetBroken, GetLocal, MaybeSkip, ct))
  , ?_assertEqual(skip, do_coveralls(ConvertAndSend, Get, GetLocalWithCoverallsTask, MaybeSkip, eunit))
  , ?_assertEqual(skip, do_coveralls(ConvertAndSend, Get, GetLocalWithCoverallsTask, MaybeSkip, ct))
  , ?_assertEqual(ok, do_coveralls(ConvertAndSend, Get, GetLocalWithCoverallsTask, MaybeSkip, 'send-coveralls'))
  , ?_assertEqual(ok, do_coveralls(ConvertWithOpts, Get, GetLocalAllOpt, MaybeSkip, eunit))
  , ?_assertEqual(ok, do_coveralls(ConvertWithOpts, Get, GetLocalAllOpt, MaybeSkip, ct))
  ].

-endif.

%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
