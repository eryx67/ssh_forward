%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2019, Vladimir G. Sekissov
%%% @doc
%%% Ssh channel for port forwarding
%%% @end
%%% Created : 21 Jul 2019 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------

%%
%%----------------------------------------------------------------------
%% Purpose: Ssh channel for port forwarding.
%%----------------------------------------------------------------------

-module(ssh_server_forward).

-behaviour(ssh_server_channel).

-export([init/1, handle_cast/2, handle_msg/2, handle_ssh_msg/2, terminate/2]).

-export([set_socket/2]).

-export([dbg_trace/3]).

-include("ssh.hrl").
-include("ssh_connect.hrl").

-record(st, { address :: string()
            , port :: non_neg_integer()
            , channel :: ssh:channel_id()
            , cm :: pid()
            , socket :: port() | undefined
            , data :: binary()
         }
       ).

set_socket(Pid, Sock) ->
    gen_server:cast(Pid, {set_socket, Sock}).

%%====================================================================
%% ssh_server_channel callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State}
%%
%% Description: Initiates the CLI
%%--------------------------------------------------------------------
init({ConnManager, Addr, Port, ChannelId}) ->
    {ok, #st{channel = ChannelId,
             cm = ConnManager,
             address = Addr,
             port = Port
            }}.

handle_cast({set_socket, Sock}, St = #st{data = Data}) ->
    case Data of
        undefined ->
            ok;
        _ ->
            ok = gen_tcp:send(Sock, Data)
    end,
    ok = inet:setopts(Sock, [{active, once}]),
    {noreply, St#st{socket = Sock, data = undefined}}.

handle_ssh_msg({ssh_cm, _, {data, _ChannelId, _, Data}}, St = #st{socket = undefined}) ->
    {ok, St#st{data = Data}};
handle_ssh_msg({ssh_cm, _, {data, ChannelId, _, Data}}, St = #st{socket = Sock}) ->
    case gen_tcp:send(Sock, Data) of
        ok ->
            {ok, St};
        {error, _} ->
            {stop, ChannelId, St}
    end;
handle_ssh_msg({ssh_cm, _, {eof, Id}}, St = #st{ channel = Id}) ->
    {stop, Id, St};
handle_ssh_msg({ssh_cm, _, {signal, Id, _}}, St = #st{ channel = Id}) ->
    {ok, St};
handle_ssh_msg({ssh_cm, _, {exit_signal, Id, _, _Error, _}}, St = #st{ channel = Id}) ->
    {stop, Id, St};
handle_ssh_msg({ssh_cm, _, {exit_status, Id, _Status}}, St = #st{ channel = Id}) ->
    {stop, Id, St}.

%%--------------------------------------------------------------------
%% Function: handle_msg(Args) -> {ok, State} | {stop, ChannelId, State}
%%
%% Description: Handles other channel messages
%%--------------------------------------------------------------------
handle_msg({tcp, Sock, Data}, St = #st{cm = ConnManager, channel = Id, socket = Sock}) ->
    ok = inet:setopts(Sock, [{active, once}]),
    ssh_connection:send(ConnManager, Id, Data),
    {ok, St};
handle_msg({tcp_closed, Sock}, St = #st{cm = ConnManager, channel = Id, socket = Sock}) ->
    ssh_connection:send_eof(ConnManager, Id),
    {stop, Id, St};
handle_msg({ssh_channel_up, Id, ConnManager}, St = #st{channel = Id, cm = ConnManager}) ->
    {ok,  St}.

%%--------------------------------------------------------------------
%% Function: terminate(Reasons, State) -> _
%%--------------------------------------------------------------------
terminate(_Reason, #st{socket = Sock}) ->
    catch gen_tcp:close(Sock),
    void.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%%################################################################
%%%#
%%%# Tracing
%%%#

dbg_trace(points,         _,  _) -> [terminate];

dbg_trace(flags,  terminate,  _) -> [c];
dbg_trace(on,     terminate,  _) -> dbg:tp(?MODULE,  terminate, 2, x);
dbg_trace(off,    terminate,  _) -> dbg:ctpg(?MODULE, terminate, 2);
dbg_trace(format, terminate, {call, {?MODULE,terminate, [Reason, State]}}) ->
    ["Port Forward Terminating:\n",
     io_lib:format("Reason: ~p,~nState:~n~s", [Reason, wr_record(State)])
    ].

?wr_record(st).