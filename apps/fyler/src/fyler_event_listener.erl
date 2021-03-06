%% Copyright
-module(fyler_event_listener).
-author("palkan").
-behaviour(gen_event).
-include("../include/log.hrl").
-include("fyler.hrl").

%% API
-export([listen/0, start_link/0]).

-export([init/1, handle_event/2, handle_call/2, handle_info/2, code_change/3,
  terminate/2]).

start_link() ->
  Pid = spawn_link(?MODULE, listen, []),
  {ok, Pid}.

listen() ->
  ?D(listen_task_events),
  fyler_event:add_sup_handler(?MODULE, []),
  receive
    Msg -> ?D({listen, Msg})
  end.

init(_Args) ->
  ?D({event_handler_set}),
  {ok,[]}.

handle_event(#fevent{type = Result, node = Node,
  task = #task{id = TaskId, file = #file{url = Url, size = Size}, type = Type, category = Category} = Task,
  stats = #job_stats{time_spent = Time, download_time = DTime, upload_time = UTime} = Stats}, State) ->

  ?D({task_complete, Type, Url, {time,Time},{download_time,DTime}}),
  case ets:info(Category) of
    undefined ->
      {ok, State};
    _ ->
      case ets:member(Category, TaskId) of
        true ->
          ets:delete(Category, TaskId),
          fyler_server:save_task_stats(Stats),
          fyler_server:send_response(Task, Stats),
          gen_server:cast(fyler_server, {task_finished, Node}),
          ToLogstash = [TaskId, Result, Category, Type, Url, Size, Node, DTime, Time, UTime],
          ?LOGSTASH("~p ~p ~p ~p ~p ~p ~p ~p ~p ~p", ToLogstash),
          {ok, State};
        false ->
          {ok, State}
      end
  end;

handle_event(#fevent{type = aborted, node = Node}, State) ->
  gen_server:cast(fyler_server, {task_finished,Node}),
  {ok, State};

handle_event(#fevent{type = pool_enabled, node = Node}, State) ->
  gen_server:cast(fyler_server, {pool_enabled, Node, true}),
  {ok, State};

handle_event(#fevent{type = pool_disabled, node = Node}, State) ->
  gen_server:cast(fyler_server, {pool_enabled, Node, false}),
  {ok, State};

handle_event(_Event, Pid) ->
  ?D([unknown_event, _Event]),
  {ok, Pid}.

handle_call(_, State) ->
  {ok, ok, State}.

handle_info(_, State) ->
  {ok, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.