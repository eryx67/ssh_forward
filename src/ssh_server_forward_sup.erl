%%%-------------------------------------------------------------------
%%% @author Vladimir G. Sekissov <eryx67@gmail.com>
%%% @copyright (C) 2019, Vladimir G. Sekissov
%%% @doc
%%% Ssh forward supervisor.
%%% @end
%%% Created : 21 Jul 2019 by Vladimir G. Sekissov <eryx67@gmail.com>
%%%-------------------------------------------------------------------

%%
%%----------------------------------------------------------------------
%% Purpose: Ssh forward supervisor.
%%----------------------------------------------------------------------
-module(ssh_server_forward_sup).

-behaviour(supervisor).

-export([start_link/1, start_child/6]).

%% Supervisor callback
-export([init/1]).

%%%=========================================================================
%%%  Internal API
%%%=========================================================================
start_link(Args) ->
    supervisor:start_link(?MODULE, [Args]).

start_child(Role, Sup, ChannelSup, Host, Port, Options) ->
    ChildSpec =
        #{id       => {Host, Port},
          start    => {ssh_server_forward_srv, start_link, [Role, self(), Host, Port, ChannelSup, Options]},
          restart  => temporary,
          type     => worker,
          modules  => [ssh_server_forward_srv]
         },
    supervisor:start_child(Sup, ChildSpec).

%%%=========================================================================
%%%  Supervisor callback
%%%=========================================================================
init(_Args) ->
    RestartStrategy = one_for_one,
    MaxR = 10,
    MaxT = 3600,
    Children = [],
    {ok, {{RestartStrategy, MaxR, MaxT}, Children}}.

%%%=========================================================================
%%%  Internal functions
%%%=========================================================================
