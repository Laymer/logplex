%% Copyright (c) 2010 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(logplex_drain_writer).
-export([start_link/1, init/1, loop/2, format_packet/3]).

-include_lib("logplex.hrl").

%% API functions
start_link(_BufferPid) ->
    proc_lib:start_link(?MODULE, init, [self()], 5000).

init(Parent) ->
    io:format("init ~p~n", [?MODULE]),
    {ok, Socket} = gen_udp:open(0, [binary]),
    {ok, RE} = re:compile("^(<\\d+>\\S+) (\\S+) \\S+ (\\S+) (\\S+) \\S+ \\S+ (.*)"),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(RE, Socket).

loop(RE, Socket) ->
    case catch logplex_queue:out(logplex_drain_buffer) of
        timeout -> ok;
        {'EXIT', {noproc, _}} ->
            exit(normal);
        {_, [{_, _, _, _, undefined, _, _}]} ->
            ok;
        {1, [{TcpDrain, AppId, ChannelId, Token, Host, Port, Msg}]} ->
            case format_packet(RE, Token, Msg) of
                undefined ->
                    io:format("Error poorly formated drain msg=~1000p~n", [Msg]);
                Packet ->
                    case send_packet(TcpDrain, Socket, AppId, ChannelId, Host, Port, Packet, 1) of
                        ok ->
                            logplex_stats:incr(logplex_stats_channels, {message_drained, AppId, ChannelId}),
                            logplex_realtime:incr(message_routed);
                        _ ->
                            ok
                    end
            end
    end,
    ?MODULE:loop(RE, Socket).

format_packet(RE, Token, Msg) ->
    case re:run(Msg, RE, [{capture, all_but_first, binary}]) of
        {match, [PriFac, Time, Source, Ps, Content]} ->
            [PriFac, <<" ">>, Time, <<" ">>, Token, <<" ">>, Source, <<" ">>, Ps, <<" - - ">>, Content];
        _ ->
            undefined
    end.

send_packet(_TcpDrain, _UdpSocket, _AppId, _ChannelId, _Host, _Port, _Packet, Count) when Count < 0 ->
    {error, failed_max_attempts};

send_packet(true = _TcpDrain, _UdpSocket, AppId, ChannelId, Host, Port, Packet, Count) ->
    case tcp_socket(AppId, ChannelId, Host, Port) of
        {ok, Sock} ->
            case gen_tcp:send(Sock, [integer_to_list(iolist_size(Packet)), <<" ">>, Packet, <<"\n">>]) of
                ok ->
                    ok;
                _Err ->
                    io:format("logplex_drain_writer app_id=~p channel_id=~p writer=~p host=~100p port=~p tcp=true event=send error=~100p~n", [AppId, ChannelId, self(), Host, Port, _Err]),
                    ets:delete(drain_sockets, {Host, Port}),
                    send_packet(true, _UdpSocket, AppId, ChannelId, Host, Port, Packet, Count-1)
            end;
        _Err ->
            ok
    end;

send_packet(false = _TcpDrain, Socket, AppId, ChannelId, Host, Port, Packet, _Count) ->
    case gen_udp:send(Socket, Host, Port, Packet) of
        ok ->
            ok;
        {error, nxdomain} ->
            io:format("nxdomin ~s:~w~n", [Host, Port]),
            {error, nxdomain};
        Err ->
            io:format("logplex_drain_writer app_id=~p channel_id=~p writer=~p host=~100p port=~p tcp=false event=send error=~100p~n", [AppId, ChannelId, self(), Host, Port, Err]),
            exit(Err)
    end.

tcp_socket(AppId, ChannelId, Host, Port) ->
    case ets:lookup(drain_sockets, {Host, Port}) of
        [] ->
            case gen_tcp:connect(Host, Port, [binary, {packet, raw}, {active, false}, {reuseaddr, true}], 100) of
                {ok, Sock} ->
                    io:format("logplex_drain_writer app_id=~p channel_id=~p writer=~p host=~100p port=~p event=connect result=OK~n", [AppId, ChannelId, self(), Host, Port]),
                    ets:insert(drain_sockets, {{Host, Port}, Sock}),
                    {ok, Sock};
                Err ->
                    io:format("logplex_drain_writer app_id=~p channel_id=~p writer=~p host=~100p port=~p event=connect result=~100p~n", [AppId, ChannelId, self(), Host, Port, Err]),
                    ets:insert(drain_sockets, {{Host, Port}, erlang:now()}),
                    Err
            end;
        [{_, {_,_,_}=Time}] ->
            %% check if connect error occured more than 30 seconds ago
            case (timer:now_diff(erlang:now(), Time) div 1000000) > 30 of
                %% if so, retry connect
                true ->
                    io:format("logplex_drain_writer app_id=~p channel_id=~p writer=~p host=~100p port=~p event=socklookup result=error~n", [AppId, ChannelId, self(), Host, Port]),
                    ets:delete(drain_sockets, {Host, Port}),
                    tcp_socket(AppId, ChannelId, Host, Port);
                false ->
                    {error, conn}
            end;
        [{_, Sock}] ->
            {ok, Sock}
    end.