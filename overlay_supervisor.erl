%% Description: This module implements a supervisor for overlay server.
%% Although the supervisor is capable of supervising several servers it is
%% assumed that for the purpose of tcp based overlay system there is only a
%% single server.

-module(overlay_supervisor).
-behaviour(supervisor).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([start_link/1]).
-export([init/1]).
%%
%% API Functions
%%

%% This function starts a supervison tree of overlay servers.
%% ServerList - a list of server names. Each name is an atom.
%% Returns - {ok,Pid} or {error,Reason}
start_link(ServerList) when is_list(ServerList), length(ServerList) > 0 ->
	supervisor:start_link({local,?MODULE}, ?MODULE, ServerList).


%%
%% Callback Functions
%%

%% Overlay supervisor init callback. 
%% Defines the overlay server offsprings of the supervisor.
init(ServerList) ->
	%%io:format("In sup init\n"),
	Servers = [{ServerName, {overlay_server, start_server, []},
            permanent,2000,worker,[overlay_server]} || ServerName<-ServerList],
  {ok,{{one_for_one,5,10}, Servers}}.