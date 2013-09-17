%%% @doc Module handling document conversion with unoconv
%%% @end

-module(doc_to_pdf_thumbs).
-include("../fyler.hrl").
-include("../../include/log.hrl").

-export([run/1,run/2]).

run(File) -> run(File,[]).


run(#file{name = Name, dir = Dir} = File,Opts) ->
  Start = ulitos:timestamp(),
  case  doc_to_pdf:run(File,Opts) of
    {ok,#job_stats{result_path = PDF}} ->  case pdf_to_thumbs:run(#file{tmp_path = PDF, name = Name, dir = Dir}) of
              {ok,#job_stats{result_path = Thumbs}} -> {ok,#job_stats{time_spent = ulitos:timestamp() - Start, result_path = PDF++Thumbs}};
              Else -> Else
            end;
    Else -> Else
  end.





