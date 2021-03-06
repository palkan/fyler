%% Copyright
-module(fyler).
-author("palkan").

-export([start/0, stop/0, upgrade/0, ping/0]).

-define(APPS,[crypto,lager]).

start() ->
  ulitos_app:ensure_started(?APPS),
  application:start(fyler).

stop() ->
  application:stop(fyler).

upgrade() ->
 ulitos_app:reload(fyler),
 ok.
 
ping() ->
  pong.



