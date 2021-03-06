/**
Copyright: Copyright (c) 2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.login.plugin;

import std.experimental.logger;
import netlib;
import pluginlib;
import voxelman.math;

import voxelman.core.config;
import voxelman.core.events;
import voxelman.net.events;
import voxelman.core.packets;
import voxelman.net.packets;
import voxelman.world.storage.coordinates;

import voxelman.config.configmanager : ConfigManager, ConfigOption;
import voxelman.command.plugin;
import voxelman.eventdispatcher.plugin;
import voxelman.net.plugin;
import voxelman.world.plugin;
import voxelman.world.clientworld;
import voxelman.graphics.plugin;

import voxelman.login.clientinfo;

shared static this()
{
	pluginRegistry.regClientPlugin(new ClientDbClient);
	pluginRegistry.regServerPlugin(new ClientDbServer);
}

struct ThisClientLoggedInEvent {
	ClientId thisClientId;
}

final class ClientDbClient : IPlugin
{
private:
	EventDispatcherPlugin evDispatcher;
	GraphicsPlugin graphics;
	NetClientPlugin connection;
	ClientWorld clientWorld;

	ConfigOption nicknameOpt;

public:
	ClientId thisClientId;
	string[ClientId] clientNames;
	bool isSpawned = false;

	// IPlugin stuff
	mixin IdAndSemverFrom!(voxelman.login.plugininfo);

	override void registerResources(IResourceManagerRegistry resmanRegistry)
	{
		ConfigManager config = resmanRegistry.getResourceManager!ConfigManager;
		nicknameOpt = config.registerOption!string("name", "Player");
	}

	override void init(IPluginManager pluginman)
	{
		graphics = pluginman.getPlugin!GraphicsPlugin;

		evDispatcher = pluginman.getPlugin!EventDispatcherPlugin;
		evDispatcher.subscribeToEvent(&onSendClientSettingsEvent);
		evDispatcher.subscribeToEvent(&handleThisClientDisconnected);

		clientWorld = pluginman.getPlugin!ClientWorld;

		connection = pluginman.getPlugin!NetClientPlugin;
		connection.registerPacketHandler!SessionInfoPacket(&handleSessionInfoPacket);
		connection.registerPacketHandler!ClientLoggedInPacket(&handleUserLoggedInPacket);
		connection.registerPacketHandler!ClientLoggedOutPacket(&handleUserLoggedOutPacket);
		connection.registerPacketHandler!ClientPositionPacket(&handleClientPositionPacket);
		connection.registerPacketHandler!SpawnPacket(&handleSpawnPacket);
		connection.registerPacketHandler!GameStartPacket(&handleGameStartPacket);
	}

	void onSendClientSettingsEvent(ref SendClientSettingsEvent event)
	{
		connection.send(LoginPacket(nicknameOpt.get!string));
	}

	void handleThisClientDisconnected(ref ThisClientDisconnectedEvent event)
	{
		isSpawned = false;
	}

	void handleGameStartPacket(ubyte[] packetData, ClientId clientId)
	{
		evDispatcher.postEvent(ThisClientConnectedEvent());
		evDispatcher.postEvent(SendClientSettingsEvent());
		connection.send(GameStartPacket());
	}

	void handleUserLoggedInPacket(ubyte[] packetData, ClientId clientId)
	{
		auto newUser = unpackPacket!ClientLoggedInPacket(packetData);
		clientNames[newUser.clientId] = newUser.clientName;
		infof("%s has connected", newUser.clientName);
		evDispatcher.postEvent(ClientLoggedInEvent(clientId));
	}

	void handleUserLoggedOutPacket(ubyte[] packetData, ClientId clientId)
	{
		auto packet = unpackPacket!ClientLoggedOutPacket(packetData);
		infof("%s has disconnected", clientName(packet.clientId));
		evDispatcher.postEvent(ClientLoggedOutEvent(clientId));
		clientNames.remove(packet.clientId);
	}

	void handleSessionInfoPacket(ubyte[] packetData, ClientId clientId)
	{
		auto loginInfo = unpackPacket!SessionInfoPacket(packetData);

		clientNames = loginInfo.clientNames;
		thisClientId = loginInfo.yourId;
		evDispatcher.postEvent(ThisClientLoggedInEvent(thisClientId));
	}

	void handleClientPositionPacket(ubyte[] packetData, ClientId peer)
	{
		auto packet = unpackPacket!ClientPositionPacket(packetData);
		//tracef("Received ClientPositionPacket(%s, %s, %s, %s)",
		//	packet.pos, packet.heading, packet.dimention, packet.positionKey);

		nansToZero(packet.pos);
		graphics.camera.position = vec3(packet.pos);

		nansToZero(packet.heading);
		graphics.camera.setHeading(vec2(packet.heading));

		clientWorld.setCurrentDimention(packet.dimention, packet.positionKey);
	}

	void handleSpawnPacket(ubyte[] packetData, ClientId peer)
	{
		auto packet = unpackPacket!SpawnPacket(packetData);
		isSpawned = true;
		clientWorld.updateObserverPosition();
	}

	string clientName(ClientId clientId)
	{
		import std.string : format;
		return clientId in clientNames ? clientNames[clientId] : format("? %s", clientId);
	}
}

final class ClientDbServer : IPlugin
{
private:
	EventDispatcherPlugin evDispatcher;
	NetServerPlugin connection;
	ServerWorld serverWorld;

public:
	ClientInfo*[ClientId] clients;

	// IPlugin stuff
	mixin IdAndSemverFrom!(voxelman.login.plugininfo);

	override void init(IPluginManager pluginman)
	{
		evDispatcher = pluginman.getPlugin!EventDispatcherPlugin;
		connection = pluginman.getPlugin!NetServerPlugin;
		serverWorld = pluginman.getPlugin!ServerWorld;

		evDispatcher.subscribeToEvent(&handleClientConnected);
		evDispatcher.subscribeToEvent(&handleClientDisconnected);

		connection.registerPacketHandler!LoginPacket(&handleLoginPacket);
		connection.registerPacketHandler!ViewRadiusPacket(&handleViewRadius);
		connection.registerPacketHandler!ClientPositionPacket(&handleClientPosition);
		connection.registerPacketHandler!GameStartPacket(&handleGameStartPacket);

		auto commandPlugin = pluginman.getPlugin!CommandPluginServer;
		commandPlugin.registerCommand("spawn", &onSpawn);
		commandPlugin.registerCommand("dim", &changeDimentionCommand);
		commandPlugin.registerCommand("add_active", &onAddActive);
		commandPlugin.registerCommand("remove_active", &onRemoveActive);
	}

	void onAddActive(CommandParams params) {
		auto cwp = clients[params.source].chunk;
		serverWorld.activeChunks.add(cwp);
		infof("add active %s", cwp);
	}

	void onRemoveActive(CommandParams params) {
		auto cwp = clients[params.source].chunk;
		serverWorld.activeChunks.remove(cwp);
		infof("remove active %s", cwp);
	}

	void onSpawn(CommandParams params)
	{
		ClientInfo* info = clients.get(params.source, null);
		if(info is null) return;
		info.pos = START_POS;
		info.heading = vec2(0,0);
		info.dimention = 0;
		info.positionKey = 0;
		connection.sendTo(params.source, ClientPositionPacket(info.pos.arrayof,
			info.heading.arrayof, info.dimention, info.positionKey));
		updateObserverBox(info);
	}

	bool isLoggedIn(ClientId clientId)
	{
		ClientInfo* clientInfo = clients[clientId];
		return clientInfo.isLoggedIn;
	}

	bool isSpawned(ClientId clientId)
	{
		ClientInfo* clientInfo = clients[clientId];
		return clientInfo.isSpawned;
	}

	string[ClientId] clientNames()
	{
		string[ClientId] names;
		foreach(id, client; clients) {
			names[id] = client.name;
		}

		return names;
	}

	string clientName(ClientId clientId)
	{
		import std.string : format;
		auto cl = clients.get(clientId, null);
		return cl ? cl.name : format("%s", clientId);
	}

	auto loggedInClients()
	{
		import std.algorithm : filter, map;
		return clients.byKeyValue.filter!(a=>a.value.isLoggedIn).map!(a=>a.value.id);
	}

	void spawnClient(vec3 pos, vec2 heading, ushort dimention, ClientId clientId)
	{
		ClientInfo* info = clients[clientId];
		info.pos = pos;
		info.heading = heading;
		info.dimention = dimention;
		++info.positionKey;
		connection.sendTo(clientId, ClientPositionPacket(pos.arrayof, heading.arrayof, dimention, info.positionKey));
		connection.sendTo(clientId, SpawnPacket());
		updateObserverBox(info);
	}

	void handleClientConnected(ref ClientConnectedEvent event)
	{
		clients[event.clientId] = new ClientInfo(event.clientId);
	}

	void handleClientDisconnected(ref ClientDisconnectedEvent event)
	{
		infof("%s %s disconnected", event.clientId,
			clients[event.clientId].name);

		connection.sendToAll(ClientLoggedOutPacket(event.clientId));
		clients.remove(event.clientId);
	}

	void changeDimentionCommand(CommandParams params)
	{
		import std.conv : to, ConvException;

		ClientInfo* info = clients[params.source];
		if (info.isSpawned)
		{
			if (params.args.length > 1)
			{
				auto dim = to!DimentionId(params.args[1]);
				if (dim == info.dimention)
					return;

				info.dimention = dim;
				++info.positionKey;
				updateObserverBox(info);

				connection.sendTo(params.source, ClientPositionPacket(info.pos.arrayof,
					info.heading.arrayof, info.dimention, info.positionKey));
			}
		}
	}

	void updateObserverBox(ClientInfo* info)
	{
		if (info.isSpawned) {
			serverWorld.chunkObserverManager.changeObserverBox(info.id, info.chunk, info.viewRadius);
		}
	}

	void handleLoginPacket(ubyte[] packetData, ClientId clientId)
	{
		auto packet = unpackPacket!LoginPacket(packetData);
		ClientInfo* info = clients[clientId];
		info.name = packet.clientName;
		info.id = clientId;
		info.isLoggedIn = true;

		infof("%s %s logged in", clientId, clients[clientId].name);

		connection.sendTo(clientId, SessionInfoPacket(clientId, clientNames));
		connection.sendToAllExcept(clientId, ClientLoggedInPacket(clientId, packet.clientName));

		evDispatcher.postEvent(ClientLoggedInEvent(clientId));
	}

	void handleGameStartPacket(ubyte[] packetData, ClientId clientId)
	{
		if (isLoggedIn(clientId))
		{
			ClientInfo* info = clients[clientId];
			info.isSpawned = true;
			spawnClient(info.pos, info.heading, info.dimention, clientId);
		}
	}

	void handleViewRadius(ubyte[] packetData, ClientId clientId)
	{
		import std.algorithm : clamp;
		auto packet = unpackPacket!ViewRadiusPacket(packetData);
		ClientInfo* info = clients[clientId];
		info.viewRadius = clamp(packet.viewRadius,
			MIN_VIEW_RADIUS, MAX_VIEW_RADIUS);
		updateObserverBox(info);
	}

	void handleClientPosition(ubyte[] packetData, ClientId clientId)
	{
		if (isSpawned(clientId))
		{
			auto packet = unpackPacket!ClientPositionPacket(packetData);
			ClientInfo* info = clients[clientId];

			// reject stale position. Dimention already have changed.
			if (packet.positionKey != info.positionKey)
				return;

			info.pos = vec3(packet.pos);
			info.heading = vec2(packet.heading);
			updateObserverBox(info);
		}
	}
}
