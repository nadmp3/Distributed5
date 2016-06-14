%% Description: This module implements an overlay client
%% which communicates with other overlay clients via tcp/ip. 
%% The communication to and from the server uses well known ports: 2233 (server)
%% and 2234 (clients).
%% The tcp/ip communication is handled by overlay_mm. Which performs actions by calling
%% a callback function process_mm_messages.

-module(overlay_client).
-behaviour(gen_server).

-record(state,{serverName,serverIP, clientName,tableId,lookupRefs=[],neighbors=[],isregistered=false,
			   serverMonitorPid = null}).
-define (NUMOFNEIGHBORS, 3).
-define (LOOKUPTIMEOUT,2000).
-define (TIMEOUT, 2000).
-define (CLIENTPORT,2234).
-define (SERVERPORT,2233).
-define (SERVERNAME, server).
-define (LOCALHOST, "localhost").

%%
%% Exported Functions
%%
-export([lookup/3, get_peers/1, client/2, start_client/2,add_file/3,get_file/3,find_file/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,process_mm_messages/1, monitor_client/2,
	 terminate/2, code_change/3, monitor_neighbor/3]).

%%
%% API Functions
%%

%% Start Client starts a client on the local machine.
%% ServerIP - the ip host name of the server machine.
%% Name - the clients name.
start_client(ServerIP, Name) when is_list(ServerIP),is_list(Name)->
	{Client_MM_Status,Client_MM_Pid} = start_client_mm(),
	case Client_MM_Status of
		ok->
			{Client_Status,Client_Pid} = gen_server:start(?MODULE, [ServerIP,Name], []),
			case Client_Status of
				ok-> Client_Pid;
				_->{error,Client_Pid}
			end;
		_->
			{error,Client_MM_Pid}
	end.
	
%% This function is invoked by the gen server init function to initialize the client.
%% ServerIP - the ip host name of the server machine.
%% Name - the clients name.
client(ServerIp,Name) when is_list(Name)->
	{Result, ServerMonitorPid} = register_to_server(ServerIp,Name),
	case Result of
		ok->
			gen_server:cast(self(),{findneighbors}),
			TableId = ets:new(files, [private]),
			{ok,#state{serverIP=ServerIp, clientName=Name, tableId = TableId, isregistered=true,
					   serverMonitorPid = ServerMonitorPid}};
		_-> 
			io:format("Client registration failed. Status = ~w ~n",[Result]),
			{stop,registrationfailed}
	end.

%% Returns a list of the pids which are the client neighbors in the overlay network.
%% ClientPid - Pid of the client.
get_peers(ClientPid)when is_pid(ClientPid)->
	overlay_mm:rpc(?LOCALHOST, ?CLIENTPORT, {get_peers, ClientPid}).

%% Searches a specified client on the overlay network, by clients name.
%% ClientPid - the client which initiates the search.
%% Nodename - the name of the requested client.
%% TTL - maximum number of hops in the overlay network.
%% Returns {ok,Pid} or {error,notfound}
lookup(ClientPid,NodeName,TTL) ->
	ClientHost = ?LOCALHOST,
	MsgRef = overlay_mm:rpc(ClientHost, ?CLIENTPORT, {lookup, {ClientPid,NodeName,TTL,myHost(),self()}}),
	receive
		{found,MsgRef,Pid, _Name} -> {ok,Pid}
		after ?LOOKUPTIMEOUT ->
			{error,notfound}
	end.

%% Adds a file resource to the local node's repository.
%% ClientPid - the client which stores the file.
%% FileName - the name of the file.
%% File- the content of the file.
add_file(ClientPid, FileName, File) ->
	overlay_mm:rpc(?LOCALHOST, ?CLIENTPORT, {add_file, {ClientPid,FileName,File}}).

%% Retreieves a file resource.
%% ClientPid - the client which initiates the search.
%% FileName - the name of the file.
%% TTL - maximum number of hops in the overlay network.
get_file(ClientPid, FileName, TTL)->
	overlay_mm:rpc(?LOCALHOST, ?CLIENTPORT, {get_file,{ClientPid, FileName, TTL}}).

%% Retreieves the node who owns a specified file resource.
%% ClientPid - the client which initiates the search.
%% FileName - the name of the file.
%% TTL - maximum number of hops in the overlay network.
%% Returns {ok, ClientName} or {error,Reason}
find_file(ClientPid,FileName, TTL)->
	overlay_mm:rpc(?LOCALHOST, ?CLIENTPORT, {find_file,{ClientPid, FileName, TTL}}).

%%
%% gen_server callbacks
%%

init([ServerIp,Name])->
	client(ServerIp,Name).

handle_call({getfile,ClientName,FileName},_From,State)->
	MyName = State#state.clientName,
	case ClientName of
		MyName-> 
			Result = ets:lookup(State#state.tableId, FileName),
			if
				length(Result)==0->
					{reply,{error,notfound},State};
				true->
					{_Name,Data} = hd(Result),
					{reply,{ok,Data},State}
			end;
		_->{reply,{error,notme},State}
	end;

handle_call({getpeers,MsgRef,_SenderPid},_From,State)->
		Reply =  {peers,MsgRef,getPidList(State)},
		{reply,Reply,State};

handle_call({addfile,FileName,File},_From,State)->
	TableId = State#state.tableId,
	ets:insert(TableId, {FileName,File}),
	{reply,ok,State};

handle_call({removeLookUpRef,MsgRef},_From,State) ->
			{noreply,State#state{lookupRefs=lists:delete(MsgRef, State#state.lookupRefs)}};

handle_call({registered,_MsgRef},_From,State)->
			{noreply,State#state{isregistered=true}}.

handle_cast({checkregistration},State)->
	if 
		State#state.isregistered->
			{noreply,State};
		true->
			receive
				after ?TIMEOUT-> ok
			end,
			{Result, ServerMonitorPid} = register_to_server(State#state.serverIP,State#state.clientName),
			case Result of
				ok->
					{noreply,State#state{isregistered=true, serverMonitorPid = ServerMonitorPid}};
				_->
					gen_server:cast(self(),{checkregistration}),
					{noreply,State}
			end
	end;

handle_cast({findneighbors},State)->
			{ReturnCode, Neighbor} = overlay_server:get_random(State#state.clientName,State#state.serverIP),
			PidList = getPidList(State),
			InNeighbors = lists:member(Neighbor, PidList),
			if 
				length(PidList)>=?NUMOFNEIGHBORS -> 
					{noreply,State};
				ReturnCode==ok andalso not InNeighbors ->
					gen_server:cast(self(),{findneighbors}),
					{NeighborHost, NeighborPid} = Neighbor,
					{Status1, ClientMonitorPid} = spawn_neighbor_monitor(NeighborHost, NeighborPid),
					case Status1 of
						ok -> {noreply,State#state{neighbors=lists:keystore(ClientMonitorPid, 1, State#state.neighbors, {ClientMonitorPid,{NeighborHost, NeighborPid}})}};
						_ -> {noreply, State}
					end;
				true->	receive
							after ?TIMEOUT-> ok
						end,
						gen_server:cast(self(),{findneighbors}),
					   	{noreply,State}
			end;


handle_cast({look,MsgRef,LookRequest,TTL,SenderHost,SenderPid},State)->
		Found = found(LookRequest, State),
		case {Found,TTL} of
			{true,TTL} -> IsOld = lists:member(MsgRef, State#state.lookupRefs),
				if
					IsOld -> {noreply,State};
					true  -> overlay_mm:rpc(SenderHost, ?CLIENTPORT, {message_router,SenderPid,{found,MsgRef,{myHost(), self()},State#state.clientName}}),
 					  {noreply,addLookupRef(State,MsgRef,self())}
				end;
			{_,0}->{noreply,State};
			{_,TTL} -> IsOld = lists:member(MsgRef, State#state.lookupRefs),
				if
					IsOld -> {noreply,State};
					true  -> [cast_client(NeighborHost, NeighborPid, {look,MsgRef,LookRequest,TTL-1,SenderHost,SenderPid}) ||
									{NeighborHost,NeighborPid}<-getPidList(State)],
						 	{noreply,addLookupRef(State,MsgRef,self())}
 				end
		end;

handle_cast({client_dead, ClientMonitorPid, _Reason}, State) ->
	IsNeighbor = lists:member(ClientMonitorPid, getRefList(State)),
	case IsNeighbor of
		true ->
			gen_server:cast(self(),{findneighbors}),
			{noreply,State#state{neighbors=lists:keydelete(ClientMonitorPid, 1, State#state.neighbors)}};
		_ -> {noreply,State}
	end;


handle_cast({shutdown},_State)->
	exit(normal);

handle_cast({server_dead,Reason},State)->
	case Reason of
		normal->
			{stop,Reason,State};
		_-> 
			receive
				after ?TIMEOUT-> ok
			end,
			gen_server:cast(self(),{checkregistration}),
			{noreply,State#state{isregistered=false}}
	end;

handle_cast(Msg, State) ->
	io:format("invalid cast message ~w\n",[Msg]),
	{noreply, State}.

handle_info(Info, State) -> 
	io:format("invalid info message ~w\n",[Info]),
	{noreply, State}.

terminate(_Reason,State) -> 
	ets:delete(State#state.tableId),
	ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%
%% Overlay mm callback Functions
%%

%% This function is called by the client overlay mm when a message arrived.
%% The purpose of this function is to apply local machine calls according to
%% messages arriving from remote machines.
%% A message is a tuple where the first elemen is a function code. According to
%% the function code the function performs local operations on the machine where
%% the overlay mm is located.
process_mm_messages(Message) ->
	case Message of
		{get_peers, ClientPid} -> get_peers1(ClientPid); 
		{lookup, {ClientPid,NodeName,TTL,SenderHost,SenderPid}} ->
			lookup1(ClientPid,NodeName,TTL,SenderHost,SenderPid);
		{cast_client,ClientPid, Message1}->
			gen_server:cast(ClientPid,Message1);
		{call_client,{ClientPid,Message1}}->
			gen_server:call(ClientPid,Message1);
		{add_file,{ClientPid,FileName,File}}->
			add_file1(ClientPid,FileName,File);
		{get_file,{ClientPid, FileName, TTL}}->
			get_file1(ClientPid, FileName, TTL);
		{find_file,{ClientPid, FileName, TTL}}->
			find_file1(ClientPid, FileName, TTL);
		{monitor_client,ServerHost,ClientPid}->
			MonitorPid = spawn(?MODULE,monitor_client,[ServerHost,ClientPid]),
			{ok, MonitorPid};
		{monitor_neighbor, ClientHost,ClientPid, NeighborPid}->
			MonitorPid = spawn(?MODULE,monitor_neighbor,[ClientHost,ClientPid, NeighborPid]),
			{ok, MonitorPid};
		{client_dead, ClientPid, ClientMonitorPid, Reason}->
			get_server:cast(ClientPid, {client_dead, ClientMonitorPid,Reason});
		{message_router,ClientPid,Message1}->
			ClientPid ! Message1;
		_ ->
			io:format("Invalid message in overlay_client:process_mm_messages: ~w~n",[Message])
	end.

%%
%% Local Functions
%%

found({node, Name}, State)->Name==State#state.clientName;
found({file, Name},State)->length(ets:lookup(State#state.tableId, Name))>0.

%% addLookupRef spawns a timer process which will notify the client to discard a referance of an old lookup
%% query.
addLookupRef(State,MsgRef,Pid)->
	spawn(fun()->receive 
					 after ?LOOKUPTIMEOUT->
						 gen_server:call(Pid,{removeLookUpRef,MsgRef})
				end
		   end),
	State#state{lookupRefs=[MsgRef|State#state.lookupRefs]}.

%% getPidList returns a list of neighbors pid.
getPidList(State)->
	lists:map(fun({_Ref,Pid})->Pid end, State#state.neighbors).

%% getRefList returns a list of monitored neighbors referances.
getRefList(State)->
	lists:map(fun({Ref,_Pid})->Ref end, State#state.neighbors).

%% Returns the hostname of the local machine.
myHost() -> {ok, Hostname} = inet:gethostname(),
			Hostname.

%% Registers a new client at the server.
%% ServerIP - the ip host name of the server machine.
%% ClientName - the clients name.
register_to_server(ServerIp,ClientName)->
	MsgRef = make_ref(),
	{Status, Reason} = call_server(ServerIp, {subscribe,myHost(),MsgRef,self(),self(), ClientName}),
	case {Status, Reason} of
		{registered, MsgRef}-> 
			{Status1, ServerMonitorPid} = spawn_server_monitor(ServerIp,self()),
			case Status1 of
				ok -> {ok, ServerMonitorPid};
				_ -> {error, ServerMonitorPid}
			end;
		_->{error,Reason}
	end.

%% This function is the loop function of the monitor client process.
%% Each client is monitored by the server. Since the client might reside on a 
%% different machine it cannot monitor the client directly.
%% Therefore the server spawns a local process for each client on the clients machine
%% which monitors the client and submits a message to the server when the client goes down.
%% ServerHost -The ip or the dns name of the server machine.
%% ClientPid - The pid of the client to be monitord.
monitor_client(ServerHost,ClientPid)->
	%%io:format("In monitor client ~w ~n",[ClientPid]),
	ClientRef = monitor(process,ClientPid),
	receive
		{'DOWN', ClientRef, process, _Pid, Reason}-> cast_server(ServerHost,{client_dead, self(), Reason})
	end.

%% This function is the loop function of the monitor client process.
%% Each client monitors it neighbors. Since neighbors might reside on a 
%% different machine it cannot monitor the client directly.
%% Therefore each client spawns a local process on the neighbors machine
%% which monitors the server which submits a message to the client when the server goes down.
%% ClientHost -The ip or the dns name of the clients machine.
%% ClientPid - The pid of the client who spawns the monitor process.
%% NeighborPid - The neighbor Pid.
monitor_neighbor(ClientHost,ClientPid, NeighborPid)->
	%%io:format("In monitor neighbor ~w by ~w ~n",[NeighborPid, ClientPid]),
	ClientRef = monitor(process,NeighborPid),
	receive
		{'DOWN', ClientRef, process, _Pid, Reason}-> cast_client(ClientHost,ClientPid, {client_dead, self(), Reason})
	end.

%% Invokes a remote gen server call for the server.
%% ServerIp - The ip or the dns name of the server machine.
%% Args - The call arguments.
call_server(ServerIP, Args)->
	overlay_mm:rpc(ServerIP, ?SERVERPORT, {callserver, Args}).

%% Invokes a remote gen server cast for the server.
%% ServerIp - The ip or the dns name of the server machine.
%% Args - The cast arguments.
cast_server(ServerIP, Args)->
	overlay_mm:rpc(ServerIP, ?SERVERPORT, {castserver, Args}).

%% Invokes a remote gen server cast for the server.
%% ClientHost - The ip or the dns name of the client machine.
%% Args - The cast arguments.
cast_client(ClientHost, ClientPid, Args)->
	overlay_mm:rpc(ClientHost, ?CLIENTPORT, {cast_client, ClientPid, Args}).

%% Spawns a server monitor process on the server's machine. Since the client
%% monitors a server which can reside on remote machines, thus cannot be done
%% directly, it spawns a process on the client machine which monitors the server
%% and notifies the client when a server goes down.
%% ClientPid - the pid of the client to be monitord.
%% ServerIP - the ip or dns name of the servers machine.
spawn_server_monitor(ServerIP,ClientPid) ->
	overlay_mm:rpc(ServerIP, ?SERVERPORT, {monitor_server,myHost(),ClientPid}).

%% Spawns client monitor process on the client's machine. Since the client
%% monitors its neighbors which can reside on remote machines, thus cannot be done
%% directly, it spawns a process on the client machine which monitors the client
%% and notifies the server when a client goes down.
%% NeighborHost - the ip adress or the dns name of the negihbor machine.
%% NeighborPid - the pid of the neighbor to be monitord.
spawn_neighbor_monitor(NeighborHost, NeighborPid)->
	overlay_mm:rpc(NeighborHost, ?CLIENTPORT, {monitor_neighbor, myHost(), self(), NeighborPid}).

%% Checks whether an instance of the client's overlay mm is running.
%% Otherwise, Such instance is spawned on the server machine.
%% A single instance of overlay mm exists on a machine and serves multiply clients.
start_client_mm()->
	case whereis(?MODULE) of
		undefined->	overlay_mm:connect(myHost(),?CLIENTPORT,?MODULE);
		MM_Pid-> {ok,MM_Pid}
	end.

%% This function is the local extension of get peers. See start server for details.
get_peers1(ClientPid)when is_pid(ClientPid)->
	MsgRef= make_ref(),
	{Status,MsgRef,Pids} = gen_server:call(ClientPid,{getpeers,MsgRef,self()}),
	case Status of
		peers -> {ok,Pids};
		Reason-> {error,Reason}
	end.

%% This function is the local extension of find file. See start server for details.
find_file1(ClientPid,FileName, TTL)->
	MsgRef = make_ref(),
	gen_server:cast(ClientPid,{look,MsgRef,{file,FileName},TTL,self()}),
	receive
		{found,MsgRef,Pid,ClientName} -> {ok,{ClientName,Pid}}
		after ?LOOKUPTIMEOUT ->
			{error,notfound}
	end.

%% This function is the local extension of get file. See start server for details.
get_file1(Pid, FileName, TTL)->
	{Status,Result} = find_file1(Pid,FileName, TTL),
	case Status of
		ok->{ClientName,ResultPid} = Result,
			gen_server:call(ResultPid, {getfile,ClientName,FileName});
		error-> {error,notfound}
	end.

%% This function is the local extension of lookup. See start server for details.
lookup1(ClientPid,NodeName,TTL,SenderHost,SenderPid) ->
	MsgRef = make_ref(),
	gen_server:cast(ClientPid,{look,MsgRef,{node,NodeName},TTL,SenderHost,SenderPid}),
	MsgRef.

%% This function is the local extension of add file. See start server for details.
add_file1(Pid, FileName, File) ->
	gen_server:call(Pid,{addfile,FileName,File}).