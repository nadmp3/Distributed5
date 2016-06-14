%% Description: This module serves as a front end to the comminication hub "middle man".
-module(overlay_mm).

-define(TCP_OPTIONS, [binary, {packet, 0}, {active, false}, {reuseaddr, true}]).

%%
%% Exported Functions
%%
-export([start/5, loop/2, rpc/3,connect/3,disconnect/1]).

%%
%% API Functions
%%

%% a synchronous call to a callback function on a remote machine. 
%% IpAddr - the ip address or dns name of the remote machine.
%% PotNo - the port on which the remote machine communication hub listens.
%% Message - the argument to the callback function.
%% Returns the term returned by the callback function or {error,status}.
rpc(IpAddr, PortNo, Message) ->
    {Status,Sock} = gen_tcp:connect(IpAddr,PortNo,?TCP_OPTIONS),
	case Status of
		ok->
			BinMessage = term_to_binary(Message),
   			gen_tcp:send(Sock,BinMessage),
    		{Status1,Response} = gen_tcp:recv(Sock,0),
			gen_tcp:close(Sock),
			case Status1 of
				ok -> binary_to_term(Response);
				_  -> io:format("In rpc tcp error. Status = ~w, Response=~w, Message = ~w, Port=~w~n",[Status1,Response,Message,PortNo]),
					  {error, Status}
			end;
		_-> 
			io:format("Connection error, Status = ~w, Reason = ~w ~n",[Status,Sock]),
			{error,connectionfailed}
	end.
    
%% Starts a communication hub on the local machine.
%% Host - the ip address or dns name of the local machine (not used).
%% PotNo - the port on which the remote machine communication hub listens.
%% Module - the mocule of the callback function. This module should export a callback function
%% process_mm_messages which serves as a message processor
%% Returns {ok,Pid of the communication hub} | {error, Reason}
connect(_Host, PortNo, Module) ->
	start(Module, PortNo, Module, process_mm_messages, []).

%% Shuts down the communication hub.
%% Pid - the pid of the hub.
disconnect(Pid) ->
	gen_server:cast(Pid, {shutdown}).

%%
%% Local Functions
%%

%% Implements the connect.
%% The function checks whether a hub already exists on the local machine. Otherwise it starts it.
%% The hub is registered locally under Name.
%% Name - the name of the hub.
%% Port - the well known port for communicating with the hub.
%% {M,F,A} - the module, function and args of the callback function.
start(Name,Port, Module, Function, Args) ->
	case whereis(Name) of
    	undefined -> 
			{Status, Socket_server_pid} = overlay_socket_server:start(Name, Port, {?MODULE, loop, {Module, Function, Args}}),
			case Status of
				ok->{ok, Socket_server_pid};
				_-> {error,Socket_server_pid }
			end;
		Pid -> {ok, Pid}
	end.

%% This is the receive side of the rpc
%% S - the socket on which we listen.
%% {M,F,A} - the module, function and args of the callback function.
loop(S, {M,F,A}) ->
    inet:setopts(S,[{active,once}]),
    receive
        {tcp,S,Data} ->
			Message = binary_to_term(Data),
            Answer = M:F(Message),
			Response = term_to_binary(Answer),
            gen_tcp:send(S,Response),
            loop(S, {M,F,A});
        {tcp_closed,S} ->
            ok
    end.

