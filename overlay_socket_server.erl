%% Description: Implements a communications hub on a local machine.
%% Overlay socket server listens on a well known port whenever a message arrives.
%% it spawns a new process which listens on the port and servs the message by calling
%% the specified callback function which performs local actions.
-module(overlay_socket_server).
-behavior(gen_server).
 
-define(TCP_OPTIONS, [binary, {packet, 0}, {active, false}, {reuseaddr, true}]).
 
-record(server_state, {
         port,
         loop,
         lsocket=null}).

%%
%% Exported Functions
%%
-export([init/1, code_change/3, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
 -export([accept_loop/1]).
 -export([start/3]).

%%
%% API Functions
%%

%% Starts a communication hub on the local machine, register it under name.
%% Name - the name of the local communication hub.
%% Port - the well known port for communicating with the hub.
%% Loop - the process the hub loop function.
start(Name, Port, Loop) ->
     State = #server_state{port = Port, loop = Loop},
     gen_server:start_link({local, Name}, ?MODULE, State, []).

%%
%% gen_server callbacks
%%
 
init(State = #server_state{port=Port}) ->
     case gen_tcp:listen(Port, ?TCP_OPTIONS) of
         {ok, LSocket} ->
             NewState = State#server_state{lsocket = LSocket},
             {ok, accept(NewState)};
         {error, Reason} ->
             {stop, Reason}
     end.
 
handle_cast({accepted, _Pid}, State=#server_state{}) ->
     {noreply, accept(State)};
	 
handle_cast({shutdown},_State)->
	%%io:format("In shutdown. \n"),
	exit(normal).
 


handle_call(_Msg, _Caller, State) -> {noreply, State}.
handle_info(_Msg, Library) -> {noreply, Library}.
terminate(_Reason, _Library) -> ok.
code_change(_OldVersion, Library, _Extra) -> {ok, Library}.
 


%%
%% Local Functions
%%


%% The loop function of the process which serves an incoming message.
%% Server - the name of the hub.
%% LSocket - the socket created by listening to the port.
%% {M,F,A} - the module, function and arguments of the callback function.
accept_loop({Server, LSocket, {M, F, A}}) ->
     {ok, Socket} = gen_tcp:accept(LSocket),
     gen_server:cast(Server, {accepted, self()}),
     M:F(Socket,A).
     
%% This fucntion spawns a message handler process.
 accept(State = #server_state{lsocket=LSocket, loop = Loop}) ->
     spawn(?MODULE, accept_loop, [{self(), LSocket, Loop}]),
     State.

