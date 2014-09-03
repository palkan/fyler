-module(task_handler).
-include("../../include/log.hrl").


-export([
  init/3,
  process_post/2,
  allowed_methods/2,
  is_authorized/2,
  content_types_accepted/2,
  content_types_provided/2,
  to_json/2,
  terminate/3
]).

init({tcp, http}, _Req, _Opts) ->
  {upgrade, protocol, cowboy_rest}.

is_authorized(Req,State) ->
  Reply = case cowboy_req:body_qs(Req) of
    {ok, X, _} -> ?D({req_data,X}),
                  case proplists:get_value(<<"fkey">>,X) of
                    undefined -> {false,<<"">>};
                    Key -> fyler_server:is_authorized(Key)
                  end;
            _ -> {false,<<"">>}
              end,
  {Reply,Req,State}.

content_types_accepted(Req, State) ->
  {[{'*',process_post}],Req,State}.

content_types_provided(Req, State) ->
  {[{{<<"text">>, <<"html">>, '*'}, to_json}],Req,State}.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_json(Req,State) ->
  {true,Req,State}.

process_post(Req, State) ->
  Resp = case cowboy_req:body_qs(Req) of
    {ok, X, _} ->
      case validate_post_data(X) of
        [Url, Type, Options] -> 
          ?D({post_data, Url, Type}), 
          case fyler_server:run_task(Url, Type, Options) of
            ok -> cowboy_req:set_resp_body(<<"ok">>, Req);
            _ -> {ok,Resp_} = cowboy_req:reply(403,Req),
                  Resp_
          end;
        false -> ?D(<<"wrong post data">>),
                  {ok,Resp_} = cowboy_req:reply(403,Req),
                  Resp_
      end;
    Else -> 
      ?D({<<"no data">>,Else}),
      {ok,Resp_} = cowboy_req:reply(403,Req),
      Resp_
  end,
  {true, Resp, State}.

validate_post_data(Data) ->
  ?D(Data),
  Keys = [<<"url">>, <<"type">>],
  Opts = proplists:get_keys(Data),
  BinData = [proplists:get_value(Key, Data) || Key <- Keys],
  Options = [{binary_to_atom(Opt,latin1),proplists:get_value(Opt, Data)} || Opt <- Opts],
  Reply = [binary_to_list(X) || X <- BinData, X =/= undefined]++[Options],
  if length(Reply) == length(Keys)+1 ->
    Reply;
    true -> false
  end.

terminate(_Reason, _Req, _State) ->
  ok.