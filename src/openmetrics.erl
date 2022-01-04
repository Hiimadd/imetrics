-module(openmetrics).

-export([get/3, counters/3, gauges/3, hist/3, hist_percentiles/3, slo/3]).

-compile(nowarn_deprecated_function). % get_stacktrace

get(SessionId, Headers, ReqBody) ->
    handle(SessionId, Headers, ReqBody, fun imetrics:get/0).

counters(SessionId, Headers, ReqBody) ->
    handle(SessionId, Headers, ReqBody, fun imetrics:get_counters/0).

gauges(SessionId, Headers, ReqBody) ->
    handle(SessionId, Headers, ReqBody, fun imetrics:get_gauges/0).

hist(SessionId, Headers, ReqBody) ->
    handle(SessionId, Headers, ReqBody, fun imetrics:get_hist/0).

hist_percentiles(SessionId, Headers, ReqBody) ->
    % We create a resource key that's the combination of the user agent and the entire
    % query string. Note: this breaks HTTP conventions (namely GET should be idempotent)
    QS = proplists:get_value(query_string, Headers, ""),
    K = qs_str_val(k, QS, ?MODULE_STRING),
    E = qs_e_val(QS),
    Key = resource_key(K, Headers),
    handle(SessionId, Headers, ReqBody,
           fun() ->
                   {Age, Data} = imetrics:get_hist_percentiles(Key, E),
                   RespHeaders = ["Content-Type: text/plain\r\n",
                                  "x-imetrics-interval-millis: ", integer_to_list(Age), "\r\n",
                                  "\r\n"],
                   {RespHeaders, Data}
           end).

slo(SessionId, Headers, ReqBody) ->
    QS = proplists:get_value(query_string, Headers, ""),
    case qs_atom_val(n, QS, ?MODULE_STRING) of
        UIdName when UIdName =/= ?MODULE_STRING ->
            case qs_str_val(u, QS, ?MODULE_STRING) of
                ?MODULE_STRING ->
                    handle(SessionId, Headers, ReqBody, fun(F, A) -> imetrics:foldl_slo(UIdName, F, A) end);
                UId ->
                    handle(SessionId, Headers, ReqBody, fun() -> imetrics:get_slo(UIdName, UId) end)
            end
    end.

qs_e_val(QS) ->
    Default = 1,
    case re:run(QS, "e=(?<n>[1-9])", [{capture, [n], list}]) of
        {match, [EStr]} ->
            try list_to_integer(EStr)
            catch _:_ ->
                      Default
            end;
        _ ->
            Default
    end.

qs_atom_val(Name, QS, Default) ->
    case qs_str_val(Name, QS, Default) of
        Default ->
            Default;
        X ->
            list_to_atom(X)
    end.

qs_str_val(Name, QS, Default) ->
    case re:run(QS, atom_to_list(Name)++"=(?<x>[^&]*)", [{capture, [x], list}]) of
        {match, [KStr]} ->
            KStr;
        _ ->
            Default
    end.

resource_key(K, Headers) ->
    iolist_to_binary([
                      "imetrics_resource_key_",
                      proplists:get_value(http_user_agent, Headers, ""),
                      "_",
                      K
                     ]).

handle(SessionId, _Headers, _ReqBody, DataFun) ->
    try
        case erlang:fun_info(DataFun, arity) of
            {arity, 2} ->
                %% Stream
                RespHeaders = "Content-Type: text/plain\r\n\r\n",
                mod_esi:deliver(SessionId, RespHeaders),
                DataFun(fun(Data, Acc0) ->
                                deliver_data(SessionId, [Data]),
                                Acc0+1
                        end,
                        0);
            {arity, 0} ->
                %% Dump
                case DataFun() of
                    [] ->
                        RespHeaders = "Content-Type: application/openmetrics-text; version=1.0.0; charset=utf-8\r\n\r\n",
                        mod_esi:deliver(SessionId, RespHeaders),
                        mod_esi:deliver(SessionId, "\n");
                    {DataHeaders, Data} ->
                        mod_esi:deliver(SessionId, DataHeaders),
                        deliver_data(SessionId, Data);
                    Data ->
                        RespHeaders = "Content-Type: application/openmetrics-text; version=1.0.0; charset=utf-8\r\n\r\n",
                        mod_esi:deliver(SessionId, RespHeaders),
                        deliver_data(SessionId, Data)
                end
        end,
        mod_esi:deliver(SessionId, "# EOF\n")
    catch Class:Reason ->
        io:format("exception ~p:~p~n", [Class, Reason]),
        io:format("~p~n", [erlang:get_stacktrace()]),
        ok
    end.

deliver_data(SessionId, Data) ->
    lists:foreach(
        fun
            ({Name, Value}) when is_number(Value) ->
                VStr = strnum(Value),
                mod_esi:deliver(SessionId, [<<Name/binary, " ">>, VStr, "\n"]);
            ({Name, Map}) when is_map(Map) ->
                MIo = serialize_proplist(maps:to_list(Map)),
                mod_esi:deliver(SessionId, [<<Name/binary, " ">>, MIo, "\n"]);
            ({Name, MappedValues}) when is_list(MappedValues) ->
                MIo = serialize_proplist(MappedValues),
                mod_esi:deliver(SessionId, [<<Name/binary, " ">>, MIo, "\n"])
        end, Data).

serialize_proplist(List) ->
    MIo = lists:map(
            fun({Key= <<"$dim">>, VStr}) ->
                    [Key, ":", VStr];
               ({Key, Value}) when is_number(Value); Value =:= 'NaN' ->
                    VStr = strnum(Value),
                    [Key, ":", VStr]
            end, List),
    string:join(MIo, " ").

strnum('NaN') -> "NaN";
strnum(N) when is_integer(N) -> integer_to_list(N);
strnum(N) when is_float(N) -> float_to_list(N, [{decimals, 6}, compact]).
