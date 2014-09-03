%% Copyright
-module(fyler_server).
-author("palkan").
-include("../include/log.hrl").
-include("fyler.hrl").

-behaviour(gen_server).

-define(TRY_NEXT_TIMEOUT, 1500).

%% Maximum time for waiting any pool to become enabled.
-define(IDLE_TIME_WM, 60000).

%% Limit on queue length. If it exceeds new pool instance should be started.
-define(QUEUE_LENGTH_WM, 30).


%% store session info
-define(T_SESSIONS, fyler_auth_sessions).

-define(SESSION_EXP_TIME, 300000).

-define(APPS, [ranch, cowlib, cowboy, mimetypes, ibrowse]).

%% API
-export([start_link/0]).

-export([run_task/3, clear_stats/0, pools/0, send_response/3, authorize/2, is_authorized/1, tasks_stats/0, save_task_stats/1]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).


-record(ets_session, {
  session_id :: string(),
  expiration_date :: non_neg_integer()
}).


%% gen_server callbacks
-record(state, {
  cowboy_pid :: pid(),
  aws_bucket :: string(),
  aws_dir :: string(),
  pools_active = [] :: list(),
  pools_busy = [] :: list(),
  busy_timer_ref = undefined,
  tasks_count = 1 :: non_neg_integer(),
  tasks = queue:new() :: queue:queue(task())
}).


%% API
start_link() ->
  ?D("Starting fyler webserver"),
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_Args) ->

  net_kernel:monitor_nodes(true),

  ulitos_app:ensure_started(?APPS),

  ?D("fyler webserver started"),

  ets:new(?T_STATS, [public, named_table, {keypos, #current_task.id}]),

  ets:new(?T_SESSIONS, [private, named_table, {keypos, #ets_session.session_id}]),

  {ok, Http} = start_http_server(),

  Buckets = ?Config(aws_s3_bucket, []),

  {ok, #state{cowboy_pid = Http, aws_bucket = Buckets, aws_dir = ?Config(aws_dir, "fyler/")}}.


%% @doc
%% Authorize user and create new session
%% @end


-spec authorize(Login :: binary(), Pass :: binary()) -> false|{ok, Token :: string()}.

authorize(Login, Pass) ->
  case ?Config(auth_pass, null) of
    null -> gen_server:call(?MODULE, create_session);
    PassHash -> L = ?Config(auth_login, none),
      case ulitos:binary_to_hex(crypto:hash(md5, binary_to_list(Pass))) == PassHash andalso binary_to_list(Login) == L of
        true -> gen_server:call(?MODULE, create_session);
        _ -> false
      end
  end.


%% @doc
%% @end

-spec is_authorized(Token :: binary()) -> boolean().

is_authorized(Token) ->
  gen_server:call(?MODULE, {is_authorized, binary_to_list(Token)}).


%% @doc
%% Remove all records from statistics ets.
%% @end

-spec clear_stats() -> true.

clear_stats() ->
  ets:delete_all_objects(?T_STATS).


%% @doc
%% Return list of pools available
%% @end

pools() ->
  gen_server:call(?MODULE, pools).


%% @doc
%% Return a list of last 50 tasks completed as #job_stats{}.
%% @end

-spec tasks_stats() -> list(#job_stats{}).

tasks_stats() ->
  Values = case pg_cli:equery("select * from tasks order by id desc limit 50") of
             {ok, _, List} -> List;
             Other -> ?D({pg_query_failed, Other})
           end,
  [fyler_utils:task_record_to_proplist(V) || V <- Values].


%% @doc
%% Save task statistics to pg
%% @end

-spec save_task_stats(#job_stats{}) -> any().

save_task_stats(#job_stats{} = Stats) ->
  ValuesString = fyler_utils:stats_to_pg_string(Stats),
  case pg_cli:equery("insert into tasks (status,download_time,upload_time,file_size,file_path,time_spent,result_path,task_type,error_msg) values (" ++ ValuesString ++ ")") of
    {ok, _} -> ok;
    Other -> ?D({pg_query_failed, Other})
  end.


%% @doc
%% Run new task.
%% @end

-spec run_task(string(), string(), list()) -> ok|false.

run_task(URL, Type, Options) ->
  gen_server:call(?MODULE, {run_task, URL, Type, Options}).


handle_call({run_task, URL, Type, Options}, _From, #state{tasks = Tasks, aws_bucket = Buckets, aws_dir = AwsDir, tasks_count = TCount} = State) ->
  case parse_url(URL, Buckets) of
    {true, Bucket, Path, Name, Ext} ->
      UniqueDir = uniqueId() ++ "_" ++ Name,
      TmpName = filename:join(UniqueDir, Name ++ "." ++ Ext),

      ?D(Options),
      Callback = proplists:get_value(callback, Options, undefined),
      TargetDir = case proplists:get_value(target_dir, Options) of
                    undefined -> filename:join(AwsDir,UniqueDir);
                    TargetDir_ -> case parse_url_dir(binary_to_list(TargetDir_), Buckets) of
                                    {true, TargetPath} -> TargetPath;
                                    _ -> ?D(wrong_target_dir, TargetDir_), filename:join(AwsDir,UniqueDir)
                                  end
                  end,
      Task = #task{id = TCount, type = list_to_atom(Type), options = Options, callback = Callback, file = #file{extension = Ext, target_dir = TargetDir, bucket = Bucket, is_aws = true, url = Path, name = Name, dir = UniqueDir, tmp_path = TmpName}},
      NewTasks = queue:in(Task, Tasks),

      ets:insert(?T_STATS, #current_task{id = TCount, type = list_to_atom(Type), url = Path, status = queued}),

      self() ! try_next_task,

      {reply, ok, State#state{tasks = NewTasks, tasks_count = TCount + 1}};
    _ -> ?D({bad_url, URL}),
      {reply, false, State}
  end;


handle_call(create_session, _From, #state{} = State) ->
  random:seed(now()),
  Token = ulitos:random_string(16),
  ets:insert(?T_SESSIONS, #ets_session{expiration_date = ulitos:timestamp() + ?SESSION_EXP_TIME, session_id = Token}),
  erlang:send_after(?SESSION_EXP_TIME, self(), {session_expired, Token}),
  {reply, {ok, Token}, State};

handle_call({is_authorized, Token}, _From, #state{} = State) ->
  Reply = case ets:lookup(?T_SESSIONS, Token) of
            [#ets_session{}] -> true;
            _ -> {false,<<"">>}
          end,
  {reply, Reply, State};


handle_call(pools, _From, #state{pools_active = P1, pools_busy = P2} = State) ->
  {reply, P1 ++ P2, State};


handle_call(_Request, _From, State) ->
  ?D(_Request),
  {reply, unknown, State}.


handle_cast({pool_enabled, Node, true}, #state{pools_busy = Pools, pools_active = Active} = State) ->
  ?D({pool_enabled, Node}),
  case lists:keyfind(Node, #pool.node, Pools) of
    #pool{} = Pool ->
      self() ! try_next_task,
      {noreply, State#state{pools_busy = lists:keydelete(Node, #pool.node, Pools), pools_active = lists:keystore(Node, #pool.node, Active, Pool#pool{enabled = true})}};
    _ -> {noreply, State}
  end;


handle_cast({pool_enabled, Node, false}, #state{pools_active = Pools, pools_busy = Busy} = State) ->
  ?D({pool_disabled, Node}),
  case lists:keyfind(Node, #pool.node, Pools) of
    #pool{} = Pool ->
      {noreply, State#state{pools_active = lists:keydelete(Node, #pool.node, Pools), pools_busy = lists:keystore(Node, #pool.node, Busy, Pool#pool{enabled = false})}};
    _ -> {noreply, State}
  end;


handle_cast({task_finished, Node}, #state{pools_active = Pools, pools_busy = Busy} = State) ->
  {NewPools, NewBusy} = decriment_tasks_num(Pools, Busy, Node),
  {noreply, State#state{pools_active = NewPools, pools_busy = NewBusy}};


handle_cast(_Request, State) ->
  ?D(_Request),
  {noreply, State}.


handle_info({session_expired, Token}, State) ->
  ets:delete(?T_SESSIONS, Token),
  {noreply, State};

handle_info({pool_connected, Node, true, Num}, #state{pools_active = Pools} = State) ->
  NewPools = lists:keystore(Node, #pool.node, Pools, #pool{node = Node, active_tasks_num = Num, enabled = true}),
  {fyler_pool, Node} ! pool_accepted,
  self() ! try_next_task,
  {noreply, State#state{pools_active = NewPools}};

handle_info({pool_connected, Node, false, Num}, #state{pools_busy = Pools} = State) ->
  NewPools = lists:keystore(Node, #pool.node, Pools, #pool{node = Node, active_tasks_num = Num, enabled = false}),
  {fyler_pool, Node} ! pool_accepted,
  {noreply, State#state{pools_busy = NewPools}};

handle_info(try_next_task, #state{pools_active = [], busy_timer_ref = undefined} = State) ->
  ?D(<<"All pools are busy; start timer to run new reserved instance">>),
  Ref = erlang:send_after(?IDLE_TIME_WM, self(), alarm_high_idle_time),
  {noreply, State#state{busy_timer_ref = Ref}};

handle_info(try_next_task, #state{pools_active = [], tasks = Tasks} = State) when length(Tasks) > ?QUEUE_LENGTH_WM ->
  ?D({<<"Queue is too big, start new instance">>, length(Tasks)}),
  %%todo:
  {noreply, State};


handle_info(try_next_task, #state{pools_active = Pools, busy_timer_ref = Ref} = State) when Ref /= undefined andalso length(Pools) > 0 ->
  erlang:cancel_timer(Ref),
  handle_info(try_next_task, State#state{busy_timer_ref = undefined});

handle_info(try_next_task, #state{tasks = Tasks, pools_active = Pools} = State) ->
  {NewTasks, NewPools} = case queue:out(Tasks) of
                           {empty, _} -> ?D(no_more_tasks),
                             {Tasks, Pools};
                           {{value, #task{id = TaskId, type = TaskType, file = #file{url = TaskUrl}} = Task}, Tasks2} ->
                             case choose_pool(Pools) of
                               #pool{node = Node, active_tasks_num = Num, total_tasks = Total} = Pool ->
                                 rpc:cast(Node, fyler_pool, run_task, [Task]),
                                 ets:insert(?T_STATS, #current_task{id = TaskId, task = Task, type = TaskType, url = TaskUrl, pool = Node, status = progress}),
                                 {Tasks2, lists:keystore(Node, #pool.node, Pools, Pool#pool{active_tasks_num = Num + 1, total_tasks = Total + 1})};
                               _ -> {Tasks, Pools}
                             end
                         end,
  Empty = queue:is_empty(NewTasks),
  if Empty
    -> ok;
    true -> erlang:send_after(?TRY_NEXT_TIMEOUT, self(), try_next_task)
  end,
  {noreply, State#state{pools_active = NewPools, tasks = NewTasks}};

handle_info(alarm_high_idle_time, State) ->
  ?D(<<"Too much time in idle state">>),
  %%todo:
  {noreply, State#state{busy_timer_ref = undefined}};

handle_info({nodedown, Node}, #state{pools_active = Pools, pools_busy = Busy, tasks = OldTasks} = State) ->
  ?D({nodedown, Node}),
  NewPools = lists:keydelete(Node, #pool.node, Pools),
  NewBusy = lists:keydelete(Node, #pool.node, Busy),

  NewTasks = case ets:match_object(?T_STATS, #current_task{pool = Node, _ = '_'}) of
               [] -> ?I("No active tasks in died pool"), OldTasks;
               Tasks -> ?I("Pool died with active tasks; restarting..."),
                 self() ! try_next_task,
                 restart_tasks(Tasks, OldTasks)
             end,

  {noreply, State#state{pools_active = NewPools, pools_busy = NewBusy, tasks = NewTasks}};

handle_info(Info, State) ->
  ?D(Info),
  {noreply, State}.

terminate(_Reason, _State) ->
  ?D(_Reason),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% @doc
%% Send response to task initiator as HTTP Post with params <code>status = success|failed</code> and <code>path</code - path to download file if success.
%% @end

-spec send_response(task(), stats(), success|failed) -> ok|list()|binary().

send_response(#task{callback = undefined}, _, _) ->
  ok;

send_response(#task{callback = Callback, file = #file{is_aws = true, bucket = Bucket, target_dir = Dir}}, #job_stats{result_path = Path}, success) ->
  ibrowse:send_req(binary_to_list(Callback), [{"Content-Type", "application/x-www-form-urlencoded"}], post, "status=ok&aws=true&bucket=" ++ Bucket ++ "&data=" ++ jiffy:encode({[{path, Path}, {dir, list_to_binary(Dir)}]}), []);

send_response(#task{callback = Callback, file = #file{is_aws = false}}, #job_stats{result_path = Path}, success) ->
  %% ibrowse:send_req(binary_to_list(Callback), [{"Content-Type", "application/x-www-form-urlencoded"}], post, "status=ok&aws=false&data=" ++ jiffy:encode({[{path, Path}]}), []);
  ?D({<<"We cannot work without aws now. Sorry(">>, Callback, Path});

send_response(#task{callback = Callback}, _, failed) ->
  ibrowse:send_req(binary_to_list(Callback), [{"Content-Type", "application/x-www-form-urlencoded"}], post, "status=failed", []).


start_http_server() ->
  Dispatch = cowboy_router:compile([
    {'_', [
      {"/", index_handler, []},
      {"/stats", stats_handler, []},
      {"/tasks", tasks_handler, []},
      {"/pools", pools_handler, []},
      {"/api/auth", auth_handler, []},
      {"/api/tasks", task_handler, []},
      {'_', notfound_handler, []}
    ]}
  ]),
  Port = ?Config(http_port, 8008),
  cowboy:start_http(http_listener, 100,
    [{port, Port}],
    [{env, [{dispatch, Dispatch}]}]
  ).


%% @doc
%% Simply choose pool with the least number of active tasks.
%%
%% todo: more intelligent logic)
%% @end

-spec choose_pool(list(#pool{})) -> #pool{}|undefined.

choose_pool([]) ->
  undefined;

choose_pool(Pools) ->
  hd(lists:keysort(#pool.active_tasks_num, Pools)).

%% @doc
%% Add tasks to the queue again.
%% @end

-spec restart_tasks(list(#current_task{}), queue:queue()) -> queue:queue().

restart_tasks([], Tasks) -> ?I("All tasks restarted."), Tasks;

restart_tasks([#current_task{task = Task}|T], Old) ->
  ?D({restarting_task, Task}),
  restart_tasks(T, queue:in(Task, Old)).






-spec decriment_tasks_num(list(#pool{}), list(#pool{}), atom()) -> {list(#pool{}), list(#pool{})}.

decriment_tasks_num([], [], _Node) ->
  {[], []};

decriment_tasks_num(A, [], Node) ->
  case lists:keyfind(Node, #pool.node, A) of
    #pool{active_tasks_num = N} = Pool when N > 0 ->
      {lists:keystore(Node, #pool.node, A, Pool#pool{active_tasks_num = N - 1}), []};
    _ -> {A, []}
  end;

decriment_tasks_num([], A, Node) ->
  case lists:keyfind(Node, #pool.node, A) of
    #pool{active_tasks_num = N} = Pool when N > 0 ->
      {[], lists:keystore(Node, #pool.node, A, Pool#pool{active_tasks_num = N - 1})};
    _ -> {[], A}
  end;

decriment_tasks_num(A, B, Node) ->
  case lists:keyfind(Node, #pool.node, A) of
    #pool{active_tasks_num = N} = Pool when N > 0 ->
      {lists:keystore(Node, #pool.node, A, Pool#pool{active_tasks_num = N - 1}), B};
    #pool{active_tasks_num = 0} -> {A, B};
    _ -> case lists:keyfind(Node, #pool.node, B) of
           #pool{active_tasks_num = N} = Pool when N > 0 ->
             {A, lists:keystore(Node, #pool.node, B, Pool#pool{active_tasks_num = N - 1})};
           _ -> {A, B}
         end
  end.

%%% @doc
%%% @end

-spec parse_url(string(),list(string())) -> {IsAws::boolean(),Bucket::string()|boolean(), Path::string(),Name::string(),Ext::string()}.

parse_url(Path, Buckets) ->
  {ok, Re} = re:compile("[^:]+://.+/([^/]+)\\.([^\\.]+)"),
  case re:run(Path, Re, [{capture, all, list}]) of
    {match, [_, Name, Ext]} ->
      {ok, Re2} = re:compile("[^:]+://([^\\.]+)\\.s3\\.amazonaws\\.com/(.+)"),
      {IsAws, Bucket,Path2} = case re:run(Path, Re2, [{capture, all, list}]) of
        {match, [_, Bucket_, Path_]} ->
          {true, Bucket_, Path_};
        _ -> {ok, Re3} = re:compile("[^:]+://([^/\\.]+).s3\\-[^\\.]+\\.amazonaws\\.com/(.+)"),
          case re:run(Path, Re3, [{capture, all, list}]) of
            {match, [_, Bucket_, Path_]} -> {true, Bucket_, Path_};
            _ -> {false, false, Path}
          end
      end,

      case IsAws of
        false -> {false,false,Path,Name,Ext};
        _ -> case lists:member(Bucket,Buckets) of
               true -> {true,Bucket,Bucket++"/"++Path2,Name,Ext};
               false -> {false,false,Path,Name,Ext}
             end
      end;
    _ ->
      false
  end.


parse_url_dir(Path, Bucket) ->
  {ok, Re2} = re:compile("[^:]+://" ++ Bucket ++ "\\.s3\\.amazonaws\\.com/(.+)"),
  case re:run(Path, Re2, [{capture, all, list}]) of
    {match, [_, Path2]} -> {true, Path2};
    _ -> {ok, Re3} = re:compile("[^:]+://([^/\\.]+).s3\\-[^\\.]+\\.amazonaws\\.com/(.+)"),
      case re:run(Path, Re3, [{capture, all, list}]) of
        {match, [_, Bucket, Path2]} -> {true, Path2};
        _ -> {false, Path}
      end
  end.

-spec uniqueId() -> string().

uniqueId() ->
  {Mega, S, Micro} = erlang:now(),
  integer_to_list(Mega * 1000000000000 + S * 1000000 + Micro).



-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").


path_to_test() ->
  ?assertEqual({false, false, "http://qwe/data.ext", "data", "ext"}, parse_url("http://qwe/data.ext", [])),
  ?assertEqual({false, false, "http://dev2.teachbase.ru/app/cpi.txt", "cpi", "txt"}, parse_url("http://dev2.teachbase.ru/app/cpi.txt", [])),
  ?assertEqual({false, false, "https://qwe/qwe/qwr/da.ta.ext", "da.ta", "ext"}, parse_url("https://qwe/qwe/qwr/da.ta.ext", ["qwo"])),
  ?assertEqual({true, "qwe", "qwe/da.ta.ext", "da.ta", "ext"}, parse_url("http://qwe.s3-eu-west-1.amazonaws.com/da.ta.ext", ["qwe"])),
  ?assertEqual({true, "qwe", "qwe/da.ta.ext", "da.ta", "ext"}, parse_url("http://qwe.s3.amazonaws.com/da.ta.ext", ["qwe", "qwo"])),
  ?assertEqual({true, "qwe", "qwe/path/to/object/da.ta.ext", "da.ta", "ext"}, parse_url("http://qwe.s3-eu-west-1.amazonaws.com/path/to/object/da.ta.ext", ["qwe"])),
  ?assertEqual({false, false, "http://qwe.s3-eu-west-1.amazonaws.com/path/to/object/da.ta.ext", "da.ta", "ext"}, parse_url("http://qwe.s3-eu-west-1.amazonaws.com/path/to/object/da.ta.ext", "q")),
  ?assertEqual(false, parse_url("qwr/data.ext", [])).


dir_url_test() ->
  ?assertEqual({true, "recordings/2/record_17/stream_1/"}, parse_url_dir("https://devtbupload.s3.amazonaws.com/recordings/2/record_17/stream_1/", "devtbupload")),
  ?assertEqual({true, "recordings/2/record_17/stream_1/"}, parse_url_dir("http://devtbupload.s3-eu-west-1.amazonaws.com/recordings/2/record_17/stream_1/", "devtbupload")),
  ?assertEqual({false, "https://2.com/record_17/stream_1/"}, parse_url_dir("https://2.com/record_17/stream_1/", "devtbupload")).


decr_num_test() ->
  A = [
    #pool{node = a, active_tasks_num = 2},
    #pool{node = b, active_tasks_num = 0}
  ],
  A1 = [
    #pool{node = a, active_tasks_num = 1},
    #pool{node = b, active_tasks_num = 0}
  ],
  B = [
    #pool{node = c, active_tasks_num = 4}
  ],
  B1 = [
    #pool{node = c, active_tasks_num = 3}
  ],

  ?assertEqual({A1, B}, decriment_tasks_num(A, B, a)),
  ?assertEqual({A, B1}, decriment_tasks_num(A, B, c)),
  ?assertEqual({A, []}, decriment_tasks_num(A, [], c)),
  ?assertEqual({[], []}, decriment_tasks_num([], [], a)),
  ?assertEqual({[], B1}, decriment_tasks_num([], B, c)),
  ?assertEqual({A, B}, decriment_tasks_num(A, B, b)).



choose_pool_test() ->
  Pool = #pool{node = a, active_tasks_num = 0},
  A = [
    #pool{node = a, active_tasks_num = 2},
    Pool
  ],
  ?assertEqual(Pool, choose_pool(A)).



authorization_test_() ->
  {"Authorization test",
    {setup,
      fun start_server_/0,
      fun stop_server_/1,
      fun(_) ->
        {inorder,
          [
            add_session_t_(),
            wrong_login_t_(),
            wrong_pass_t_(),
            is_authorized_t_(),
            is_authorized_failed_t_()
          ]
        }
      end
    }
  }.


start_server_() ->
  ok = application:start(fyler),
  application:set_env(fyler,auth_pass,ulitos:binary_to_hex(crypto:hash(md5, "test"))).


stop_server_(_) ->
  application:stop(fyler).


add_session_t_() ->
  P = "test",
  ?_assertMatch({ok, _}, fyler_server:authorize(list_to_binary(?Config(auth_login, "")), list_to_binary(P))).


wrong_login_t_() ->
  P = "test",
  ?_assertEqual(false, fyler_server:authorize(<<"badlogin">>, list_to_binary(P))).

wrong_pass_t_() ->
  P = "wqe",
  ?_assertEqual(false, fyler_server:authorize(?Config(auth_login, ""), list_to_binary(P))).

is_authorized_t_() ->
  P = "test",
  {ok, Token} = fyler_server:authorize(list_to_binary(?Config(auth_login, "")), list_to_binary(P)),
  ?_assertEqual(true, fyler_server:is_authorized(list_to_binary(Token))).

is_authorized_failed_t_() ->
  ?_assertMatch({false,_}, fyler_server:is_authorized(<<"123456">>)).


-endif.
