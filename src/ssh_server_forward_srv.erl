%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2019, Vladimir G. Sekissov
%%% @doc
%%% Ssh forward listener.
%%% @end
%%% Created : 21 Jul 2019 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------

%%
%%----------------------------------------------------------------------
%% Purpose: Ssh forward listener.
%%----------------------------------------------------------------------
-module(ssh_server_forward_srv).

-behaviour(gen_server).

-export([start_link/5]).

%% gen_server callback
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("ssh.hrl").
-include("ssh_connect.hrl").

-define(tcp_options,[binary,
                     {keepalive, true},
                     {active, false},
                     {reuseaddr, true},
                     {nodelay, true},
                     {backlog, 1024},
                     {send_timeout, 5000},
                     {send_timeout_close, true}
                    ]).

-record(st, {cm :: pid()
            , socket :: port()
            , acceptor :: any()
            , channel_supervisor :: pid()
            , host :: binary()
            , port :: non_neg_integer()
            , options :: proplists:proplist()
            , pid2id :: #{pid() := ssh:channel_id()}
            , id2pid :: #{ssh:channel_id() := pid()}
            }).

%%%=========================================================================
%%%  Internal API
%%%=========================================================================
-spec start_link(pid(), binary(), 0..65535, pid(), proplists:proplist()) ->
                        {ok, pid(), non_neg_integer()}.
start_link(ConnectionManager, Host, Port, ChannelSup, Options) ->
    proc_lib:start_link(?MODULE, init, [{ConnectionManager, Host, Port, ChannelSup, Options}]).

%%%=========================================================================
%%%  gen_server callback
%%%=========================================================================
-spec init({pid(), binary(), 0..65535, pid(), proplists:proplist()}) -> any().
init({ConnManager, Host, Port, ChannelSup, Options}) ->
    LsnOpts =
        case Host of
            <<"0.0.0.0">> ->
                [inet];
            <<"::">> ->
                [inet6];
            <<"localhost">> ->
                [{ip, {127, 0, 0, 1}}];
            _ ->
                {ok, IP} = inet:parse_address(Host),
                [{ip, IP}]
        end,
    case gen_tcp:listen(Port, LsnOpts ++ ?tcp_options) of
        {ok, LsnSock} ->
            {ok, LsnPort} = inet:port(LsnSock),
            {ok, Ref} = prim_inet:async_accept(LsnSock, -1),
            proc_lib:init_ack({ok, self(), LsnPort}),
            St = #st{cm = ConnManager
                    , socket = LsnSock
                    , acceptor = Ref
                    , channel_supervisor = ChannelSup
                    , options = Options
                    , host = Host
                    , port = LsnPort
                    , pid2id = #{}
                    , id2pid = #{}
                    },
            gen_server:enter_loop(?MODULE, [], St);
        {error, Reason} ->
            exit(Reason)
    end.

-spec handle_call(X, reference(), #st{}) ->
                         {stop, {unknown_request, X}, {unknown_request, X}, #st{}}.
handle_call(Request, _From, St) ->
  {stop, {unknown_request, Request}, {unknown_request, Request}, St}.

-spec handle_cast(X, #st{}) ->
                         {stop, {unknown_cast, X}, #st{}}.
handle_cast(Msg, St) ->
    {stop, {unknown_cast, Msg}, St}.

-spec handle_info(X, #st{}) ->
                         {noreply, #st{}} | {stop, {unknown_info, X}, #st{}}.
handle_info({inet_async, LsnSock, Ref, {ok, AccSock}},
            St = #st{socket = LsnSock, acceptor = Ref, host = Host, port = Port}) ->

    case set_sockopt(LsnSock, AccSock) of
        ok ->
            ok;
        {error, Reason} ->
            exit({set_sockopt, Reason})
    end,
    {ok, {ClientIP, ClientPort}} = inet:peername(AccSock),

    ClientAddr = list_to_binary(inet_parse:ntoa(ClientIP)),
    ClientAddrLen = byte_size(ClientAddr),

    HostLen = byte_size(Host),

    Data = <<?DEC_BIN(Host, HostLen), ?UINT32(Port),
             ?DEC_BIN(ClientAddr, ClientAddrLen), ?UINT32(ClientPort)
           >>,

    St1 = start_channel(AccSock, ClientAddr, ClientPort, Data, St),

    case prim_inet:async_accept(LsnSock, -1) of
        {ok, NewRef} ->
            {noreply, St1#st{acceptor = NewRef}};
        {error, Err2} ->
            {stop, Err2, St1}
    end;
handle_info({inet_async, LsnSock, Ref, Error}, #st{socket = LsnSock, acceptor = Ref} = St) ->
    {stop, Error, St};
handle_info({'DOWN', _MR, process, Pid, _Info}, St) ->
    {noreply, del_connection(Pid, St)};
handle_info(Msg={ssh_cm, _, Data}, St) ->
    case ssh_cm_channel_id(Data) of
        undefined ->
            logger:error("can't find channel id for ssh_cm ~p", [Msg]),
            ok;
        Id ->
            case connection_pid(Id, St) of
                undefined ->
                    logger:error("can't find channel pid for id ~p", [Id]);
                Pid ->
                    Pid ! Msg,
                    ok
            end
    end,
    {noreply, St};
handle_info(Info, St) ->
    {stop, {unknown_info, Info}, St}.

-spec terminate(any(), #st{}) -> any().
terminate(_Reason, _St) ->
  ok.

-spec code_change(any(), any(), any()) -> {ok, any()}.
code_change(_OldVsn, St, _Extra) -> {ok, St}.

%% ====================================================================
%% Internal functions
%% ====================================================================

start_channel(Sock, Addr, Port, Data, St = #st{cm = ConnManager,
                                               channel_supervisor = ChannelSup,
                                               host = Host, port = Port,
                                               options = Opts}) ->
    case max_num_channels_not_exceeded(ChannelSup, Opts) of
        false ->
            ok = gen_tcp:close(Sock),
            St;
        true ->
            case ssh_connection_handler:open_channel(ConnManager, "forwarded-tcpip",
                                                     Data,
                                                     ?DEFAULT_WINDOW_SIZE, ?DEFAULT_PACKET_SIZE,
                                                     infinity) of
                {open, Id} ->
                    Args = {ConnManager, Addr, Port, Id},
                    {ok, Pid} =
                        ssh_server_channel_sup:start_child(ChannelSup, ConnManager, ssh_server_forward,
                                                           Id, Args, undefined),

                    ok = gen_tcp:controlling_process(Sock, Pid),
                    ok = ssh_server_forward:set_socket(Pid, Sock),
                    monitor(process, Pid),
                    St1 = add_connection(Pid, Id, St),
                    St1;
                Error ->
                    logger:error("opening forward cahnnel for ~p:~p ~p", [Host, Port, Error]),
                    ok = gen_tcp:close(Sock),
                    St
            end
    end.

ssh_cm_channel_id(Data) when is_tuple(Data) ->
    element(2, Data);
ssh_cm_channel_id(_) ->
    undefined.

add_connection(Pid, Id, St = #st{pid2id = P2I, id2pid = I2P}) ->
    St#st{pid2id = P2I#{Pid => Id}, id2pid = I2P#{Id => Pid}}.

del_connection(Pid, St = #st{pid2id = P2I, id2pid = I2P}) when is_pid(Pid) ->
    case connection_id(Pid, St) of
        undefined ->
            St;
        Id ->
            St#st{pid2id = maps:remove(Pid, P2I), id2pid = maps:remove(Id, I2P)}
    end;
del_connection(Id, St = #st{pid2id = P2I, id2pid = I2P}) ->
    case connection_pid(Id, St) of
        undefined ->
            St;
        Pid ->
            St#st{pid2id = maps:remove(Pid, P2I), id2pid = maps:remove(Id, I2P)}
    end.

connection_id(Pid, #st{pid2id = P2I}) when is_pid(Pid) ->
    maps:get(Pid, P2I, undefined).

connection_pid(Id, #st{id2pid = I2P}) ->
    maps:get(Id, I2P, undefined).

-spec set_sockopt(port(), port()) -> ok | {error, any()}.
set_sockopt(LsnSock, AccSocket) ->
    true = inet_db:register_socket(AccSocket, inet_tcp),
    case prim_inet:getopts(LsnSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
        {ok, Opts} ->
            case prim_inet:setopts(AccSocket, Opts) of
                ok ->
                    ok;
                Err={error, _} ->
                    gen_tcp:close(AccSocket),
                    Err
            end;
        Err={error, _} ->
            gen_tcp:close(AccSocket),
            Err
    end.

max_num_channels_not_exceeded(ChannelSup, Opts) ->
    MaxNumChannels = ?GET_OPT(max_channels, Opts),
    NumChannels = length([x || {_,_,worker,[ssh_server_channel]} <-
                                   supervisor:which_children(ChannelSup)]),
    NumChannels < MaxNumChannels.
