%% Description: This module implements overlay server which communicates with overlay clients
%% via tcp/ip. The communication to and from the server uses well known ports: 2233 (server)
%% and 2234 (clients).
%% The tcp/ip communication is handled by overlay_mm. Which performs actions by calling
%% a callback function process_mm_messages.
%% It is assumed that there is only one server which is registered on the local
%% machine under the name - server.

-module(overlay_server).
-behaviour(gen_server).
-ver(1.0).

-define (CLIENTS,clients).
-define (SERVERPORT,2233).
-define (CLIENTPORT,2234).
-define (SERVERNAME, server).

%%
%% Exported Functions
%%
-export([stop/1, get_random/2, get_live/1, get_live1/1,start_server/0,switch_version/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,process_mm_messages/1, monitor_server/2,
	 terminate/2, code_change/3]).

%%
%% API Functions
%%


%% start_server spawns a robust server and registers it under a fixed servername - server.
%% The function checks whether an instance of the servers overlay_mm is up and running if
%% not it launches such instant.
%% Returns the pid of the server.
start_server()->
	{Start_Link_Status,ServerPid} = start_server1(?SERVERNAME),
	case Start_Link_Status of
		ok->
			{Server_MM_Status,Server_MM_Pid} = start_server_mm(),
			case Server_MM_Status of
				ok-> {ok,ServerPid};
				_->{error,Server_MM_Pid}
			end;
		_->
			{error,ServerPid}
	end.

%% Stops the server.
%% IpAddr - the ip host name of the server machine.
%% Returns ok if the operation is succesful, otherwise {error, Reason}.
stop(IpAddr) -> 
	overlay_mm:rpc(IpAddr, ?SERVERPORT, {stop, ?SERVERNAME}).

%% Query server name for list of all live clients.
%% IpAddr - the ip host name of the server machine.
%% Returns a list of all live clients.
get_live(IpAddr)->
	overlay_mm:rpc(IpAddr, ?SERVERPORT, {get_live, ?SERVERNAME}).

%% Query ServerName for random active node's pid different from From.
%% ServerIp - the ip host name of the server machine.
%% Returns {ok,Pid} of a random network node or {error,Reason}. 
get_random(Client_name,ServerIp) when is_list(Client_name)->
	overlay_mm:rpc(ServerIp, ?SERVERPORT, {get_random, {?SERVERNAME,Client_name}}).

%% Switch version downgrades overlay_server to use orddict dictionary.
%% Returns the upgraded state
switch_version(ServerName)->
	sys:suspend(ServerName),
	sys:change_code(ServerName, ServerName, [1.0], []),
	sys:resume(ServerName).

%%
%% gen_server callbacks
%%

cast_client(ClientIP,ClientPid,Args)->
	overlay_mm:rpc(ClientIP, ?CLIENTPORT, {cast_client,ClientPid,Args}).

init([]) -> 
	{ok, orddict:new()}.
 

handle_call({subscribe,ClientHost,Ref,_SenderPid,ClientPid, ClientName},_From,State) ->
	{Status, ClientMonitorPid} = spawn_client_monitor(ClientHost,ClientPid, myHost()),
	case Status of
		ok->
			State1 = orddict:filter(fun (_Key,{_ClientHost, _ClientPid,ClientName1})-> ClientName1 =/= ClientName end, State),
			NewState = orddict:store(ClientMonitorPid, {ClientHost, ClientPid,ClientName}, State1),
    		Reply = {registered, Ref},
    		{reply, Reply, NewState};
		_->
			{error,ClientMonitorPid}
	end;

handle_call({getlive,_Pid},_From,State) ->
    LiveClients = [ClientName || {_Key,{_Host, _Pid1,ClientName}}<-orddict:to_list(State)],
	Reply = {ok,LiveClients},
	{reply,Reply,State};

handle_call({getrandom, MsgRef, Client_name},_From,State)->
	Reply = case getRandom(State, Client_name) of
				none -> {randomClient, MsgRef, nil};
				Pid -> {randomClient, MsgRef, Pid}
			end,
	{reply,Reply,State}.

handle_cast({shutdown},_State)->
	exit(normal);

handle_cast({client_dead, ClientMonitorPid, _Reason},State)->
	{noreply,orddict:erase(ClientMonitorPid,State)};

handle_cast(Msg, State) -> 
	io:format("In handle cast. Msg is ~w, State is ~w \n",[Msg,State]),
	{noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},State)->
	{noreply,orddict:erase(Ref,State)};

handle_info(Info, State) ->
	io:format("In handle info. info is ~w, State is ~w \n",[Info,State]),
	{noreply, State}.

terminate(_Reason, _State) -> 
	ok.

code_change(OldVsn, State, _Extra) ->
	CurrentVersion = hd(OldVsn),
	case CurrentVersion of
		1.0-> NewState = buildDictFromEts(State),
			  {ok, NewState};
		_->{error,badversion}
	end.



%%
%% overlay_mm Callback Functions
%%

%% This function is called by the server overlay mm when a message arrived.
%% The purpose of this function is to apply local machine calls according to
%% messages arriving from remote machines.
%% A message is a tuple where the first elemen is a function code. According to
%% the function code the function performs local operations on the machine where
%% the overlay mm is located.
process_mm_messages(Message) ->
	case Message of
		{get_live, ServerName} -> get_live1(ServerName); 
		{get_random, {ServerName, Client_name}} ->
			get_random1(ServerName, Client_name); 
		{stop, ServerName} -> stop1(ServerName);
		{callserver, Args}-> gen_server:call(?SERVERNAME, Args);
		{castserver, Args}-> gen_server:cast(?SERVERNAME, Args);
		{monitor_server,ClientHost,ClientPid}->
			MonitorPid = spawn(?MODULE,monitor_server,[ClientPid,ClientHost]),
			{ok, MonitorPid};
		{subscribe,Args}->gen_server:call(?SERVERNAME, Args);
		_ ->
			io:format("Invalid message in overlay_server:process_mm_messages: ~w~n",[Message])
	end.

%%
%% Local Functions
%%

%% buildDictFromEts builds orddict based state from ets based state
%% Returns the new state
buildDictFromEts(_State)->
	Clients=ets:tab2list(?CLIENTS),
	buildDict(orddict:new(),Clients).
	

buildDict(State, [])->State;
buildDict(State,[{Ref, Pid, Name}|T])->buildDict(orddict:store(Ref, {Pid, Name}, State),T).

%% getRandom returns a random client registered to the server.
%% Returns: The pid of a random client.
getRandom(State, Client_name) ->
	Len = orddict:size(State),
	case Len of
		0 -> none;
		1 -> [{_Ref, {Host, Pid, Name}}] = orddict:to_list(State),
			  case Name of
					Client_name -> none;
				    _ -> {Host, Pid}
			  end;
		_ ->  {_Ref, {Host, Pid, Name}} = lists:nth(random:uniform(Len), orddict:to_list(State)),
			  case Name of
					Client_name -> getRandom(State, Client_name);
				    _ -> {Host, Pid}
			  end
	end.

%% This function is the loop function of the monitor server process.
%% Each client monitors the server. Since the client might reside on a 
%% different machine it cannot monitor the server directly.
%% Therefore each client spawns a local process on the servers machine
%% which monitors the server which submits a message to the client when the server goes down.
%% ClientHost -The ip or the dns name of the clients machine.
%% ClientPid - The pid of the client who spawns the monitor process.
monitor_server(ClientPid,ClientHost)->
	ServerRef = monitor(process,whereis(?SERVERNAME)),
	receive
		{'DOWN', ServerRef, process, _Pid, Reason}-> cast_client(ClientHost,ClientPid,{server_dead, Reason})
	end.

%% Returns the hostname of the local machine.
myHost() -> {ok, Hostname} = inet:gethostname(),
			Hostname.

%% Spawns client monitor process on the client's machine. Since the server
%% monitors clients which can reside on remote machines, thus cannot be done
%% directly, it spawns a process on the client machine which monitors the client
%% and notifies the server when a client goes down.
%% ClientHost - the ip adress or the dns name of the client machine.
%% ClientPid - the pid of the client to be monitord.
%% ServerHost - the ip or dns name of the servers machine.
spawn_client_monitor(ClientHost,ClientPid,ServerHost) ->
	overlay_mm:rpc(ClientHost, ?CLIENTPORT, {monitor_client,ServerHost,ClientPid}).

%% Checks whether an instance of the server's overlay mm is running.
%% Otherwise, Such instance is spawned on the server machine.
start_server_mm()->
	case whereis(?MODULE) of
		undefined->	overlay_mm:connect(myHost(),?SERVERPORT,?MODULE);
		MM_Pid-> {ok,MM_Pid}
	end.

%% This function is the local extension of start server. See start server for details.
start_server1(ServerName) when is_atom(ServerName)->
	gen_server:start_link({local, ServerName}, ?MODULE, [], []).

%% This function is the local extension of stop. See start server for details.
stop1(ServerName) -> gen_server:cast(ServerName, {shutdown}).

%% This function is the local extension of get live. See start server for details.
get_live1(ServerName) when is_atom(ServerName) ->
	{Status,Result} = gen_server:call(ServerName,{getlive,self()}),
	case Status of
		ok -> {ok,Result}; %%Result is the ClientList
		_-> {error,Result} %%Result is the reason
	end.

%% This function is the local extension of get random. See start server for details.
get_random1(ServerName, Client_name)when is_atom(ServerName),is_list(Client_name)->
	MsgRef = make_ref(),
	{Status,MsgRef,Result} = gen_server:call(ServerName,{getrandom,MsgRef,Client_name}),
	case {Status,Result} of
		{randomClient,nil} -> {error, noclients};
		{randomClient,Pid} -> {ok, Pid};
		{Status,_} -> {error, Status}
	end.






    

