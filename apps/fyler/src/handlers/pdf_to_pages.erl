%%% @doc Module handling generating thumbs from pdf
%%% @end

-module(pdf_to_pages).
-include("../fyler.hrl").
-include("../../include/log.hrl").

-export([run/1, run/2]).

-define(COMMAND(In, OutName), "gs -dNOPAUSE -dBATCH -dSAFER -sDEVICE=jpeg  -sOutputFile=\"" ++ OutName ++ "_%d.png\" -r200 -q \"" ++ In ++ "\" -c quit").
-define(COMMAND2(In), "jpegtran -copy none -progressive \"" ++ In ++ "\"").

run(File) -> run(File, []).

run(#file{tmp_path = Path, name = Name, dir = Dir} = File, _Opts) ->
  Start = ulitos:timestamp(),
  case pdf_to_thumbs:run(File) of
    {ok, #job_stats{result_path = Thumbs}} ->
      PagesDir = Dir ++ "/pages",
      ok = file:make_dir(PagesDir),
      ?D({"command", ?COMMAND(Path, PagesDir ++ "/" ++ Name)}),
      Data = os:cmd(?COMMAND(Path, PagesDir ++ "/" ++ Name)),
      ?D({gs_data, Data}),
      case filelib:wildcard("*.jpg", PagesDir) of
        [] -> {error, Data};
        List ->
          make_progressive_jpeg(List),
          JSON = jiffy:encode({
            [
              {name, list_to_binary(Name)},
              {dir, <<"pages">>},
              {length, length(List)},
              {thumbs, [list_to_binary(T) || T <- List]}
            ]
          }),
          JSONFile = Dir ++ "/" ++ Name ++ ".pages.json",
          {ok, F} = file:open(JSONFile, [write]),
          file:write(F, JSON),
          file:close(F),
          {ok, #job_stats{time_spent = ulitos:timestamp() - Start, result_path = [list_to_binary(JSONFile)|Thumbs]}}
      end;
    Else -> Else
  end.



make_progressive_jpeg(List) ->
  [?COMMAND2(F) || F <- List].




