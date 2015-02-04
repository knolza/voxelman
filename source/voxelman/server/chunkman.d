/**
Copyright: Copyright (c) 2013-2014 Andrey Penechko.
License: a$(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.server.chunkman;

import std.concurrency : Tid, thisTid, send, receiveTimeout;
import std.datetime : msecs;
import std.stdio : writef, writeln, writefln;
import core.thread : thread_joinAll;

import dlib.math.vector : vec3, ivec3;

import netlib;

import voxelman.block;
import voxelman.blockman;
import voxelman.chunk;
import voxelman.chunkgen;
import voxelman.chunkmesh;
import voxelman.config;
import voxelman.meshgen;
import voxelman.server.clientinfo;
import voxelman.server.serverplugin;
import voxelman.packets;
import voxelman.storageworker;
import voxelman.utils.workergroup;

version = Disk_Storage;


struct ChunkObserverList
{
	ClientId[] observers;

	ClientId[] opIndex()
	{
		return observers;
	}

	bool empty() @property
	{
		return observers.length == 0;
	}

	void add(ClientId clientId)
	{
		observers ~= clientId;
	}

	void remove(ClientId clientId)
	{
		import std.algorithm : remove, SwapStrategy;
		observers = remove!((a) => a == clientId, SwapStrategy.unstable)(observers);
	}
}

ChunkRange calcChunkRange(ivec3 coord, size_t viewRadius)
{
	auto size = viewRadius*2 + 1;
	return ChunkRange(cast(ivec3)(coord - viewRadius),
		ivec3(size, size, size));
}

///
struct ChunkMan
{
	@disable this();
	this(ServerConnection connection)
	{
		assert(connection);
		this.connection = connection;
	}

	ServerConnection connection;
	Chunk*[ivec3] chunks;
	ChunkObserverList[ivec3] chunkObservers;

	Chunk* chunksToRemoveQueue; // head of slist. Follow 'next' pointer in chunk
	size_t numChunksToRemove;
	
	// Stats
	size_t numLoadChunkTasks;
	size_t totalLoadedChunks;
	size_t totalObservedChunks;
	
	BlockMan blockMan;

	WorkerGroup!(chunkGenWorkerThread) genWorkers;
	WorkerGroup!(storageWorkerThread) storeWorker;

	void init()
	{
		blockMan.loadBlockTypes();

		genWorkers.startWorkers(NUM_WORKERS, thisTid);
		version(Disk_Storage)
			storeWorker.startWorkers(1, thisTid, SAVE_DIR);
	}

	void stop()
	{
		writefln("saving chunks %s", chunks.length);

		foreach(chunk; chunks.byValue)
			addToRemoveQueue(chunk);

		size_t toBeDone = chunks.length;
		uint donePercentsPrev;

		while(chunks.length > 0)
		{
			update();

			auto donePercents = cast(float)(toBeDone - chunks.length) / toBeDone * 100;
			if (donePercents >= donePercentsPrev + 10)
			{
				donePercentsPrev += ((donePercents - donePercentsPrev) / 10) * 10;
				writefln("saved %s%%", donePercentsPrev);
			}
		}

		genWorkers.stopWorkers();

		version(Disk_Storage)
			storeWorker.stopWorkersWhenDone();

		thread_joinAll();

	}

	void update()
	{
		bool message = true;
		while (message)
		{
			message = receiveTimeout(0.msecs,
				(immutable(ChunkGenResult)* data){onChunkLoaded(cast(ChunkGenResult*)data);}
				);
		}

		updateChunks();
	}

	void removeObserver(ClientId clientId)
	{
		auto region = connection.clientStorage[clientId].visibleRegion;
		foreach(chunkCoord; region.chunkCoords)
		{
			removeChunkObserver(chunkCoord, clientId);
		}
	}

	void updateObserverPosition(ClientId clientId)
	{
		import std.conv : to;

		ClientInfo* clientInfo = connection.clientStorage[clientId];
		assert(clientInfo, "clientStorage[clientId] is null");
		ChunkRange oldRegion = clientInfo.visibleRegion;
		vec3 cameraPos = clientInfo.pos;
		size_t viewRadius = clientInfo.viewRadius;

		ivec3 chunkPos = ivec3(
			to!int(cameraPos.x) / CHUNK_SIZE,
			to!int(cameraPos.y) / CHUNK_SIZE,
			to!int(cameraPos.z) / CHUNK_SIZE);
		ChunkRange newRegion = calcChunkRange(chunkPos, viewRadius);
		if (oldRegion == newRegion) return;
		
		onClientVisibleRegionChanged(oldRegion, newRegion, clientId);
		connection.clientStorage[clientId].visibleRegion = newRegion;
	}

	void onClientVisibleRegionChanged(ChunkRange oldRegion, ChunkRange newRegion, ClientId clientId)
	{
		if (oldRegion.empty)
		{
			writefln("observe region");
			observeRegion(newRegion, clientId);
			return;
		}

		auto chunksToRemove = oldRegion.chunksNotIn(newRegion);

		// remove chunks
		foreach(chunkCoord; chunksToRemove)
		{
			removeChunkObserver(chunkCoord, clientId);
		}

		// load chunks
		// ivec3[] chunksToLoad = newRegion.chunksNotIn(oldRegion).array;
		// sort!((a, b) => a.euclidDist(observerPosition) > b.euclidDist(observerPosition))(chunksToLoad);
		foreach(chunkCoord; newRegion.chunksNotIn(oldRegion))
		{
			addChunkObserver(chunkCoord, clientId);
		}
	}

	void observeRegion(ChunkRange region, ClientId clientId)
	{
		foreach(int x; region.coord.x..(region.coord.x + region.size.x))
		foreach(int y; region.coord.y..(region.coord.y + region.size.y))
		foreach(int z; region.coord.z..(region.coord.z + region.size.z))
		{
			addChunkObserver(ivec3(x, y, z), clientId);
		}
	}

	void addChunkObserver(ivec3 coord, ClientId clientId)
	{
		if (!isChunkInWorldBounds(coord)) return;
		bool alreadyLoaded = loadChunk(coord);
		chunkObservers[coord].add(clientId);
		if (alreadyLoaded)
		{
			sendChunkToObservers(coord);
		}
		++totalObservedChunks;
	}

	void removeChunkObserver(ivec3 coord, ClientId clientId)
	{
		if (!isChunkInWorldBounds(coord)) return;
		chunkObservers[coord].remove(clientId);
		if (chunkObservers[coord].empty)
			addToRemoveQueue(getChunk(coord));
		--totalObservedChunks;
	}

	void onChunkLoaded(ChunkGenResult* data)
	{
		//writefln("Chunk data received in main thread");

		Chunk* chunk = getChunk(data.coord);
		assert(chunk !is null);

		chunk.hasWriter = false;
		chunk.isLoaded = true;

		assert(!chunk.isUsed);

		++totalLoadedChunks;
		--numLoadChunkTasks;

		chunk.isVisible = true;
		if (data.chunkData.uniform)
		{
			chunk.isVisible = blockMan.blocks[data.chunkData.uniformType].isVisible;
		}
		chunk.data = data.chunkData;

		if (chunk.isMarkedForDeletion)
		{
			return;
		}

		// Send data to observers
		sendChunkToObservers(data.coord);
	}

	void sendChunkToObservers(ivec3 coord)
	{
		connection.sendTo(chunkObservers[coord][],
			ChunkDataPacket(coord, chunks[coord].data));
	}

	void printList(Chunk* head)
	{
		while(head)
		{
			writef("%s ", head);
			head = head.next;
		}
		writeln;
	}

	void printAdjacent(Chunk* chunk)
	{
		void printChunk(Side side)
		{
			byte[3] offset = sideOffsets[side];
			ivec3 otherCoord = ivec3(chunk.coord.x + offset[0],
									chunk.coord.y + offset[1],
									chunk.coord.z + offset[2]);
			Chunk* c = getChunk(otherCoord);
			writef("%s", c is null ? "null" : "a");
		}

		foreach(s; Side.min..Side.max)
			printChunk(s);
		writeln;
	}

	void updateChunks()
	{
		processRemoveQueue();
	}

	void processRemoveQueue()
	{
		Chunk* chunk = chunksToRemoveQueue;

		while(chunk)
		{
			assert(chunk !is null);
			//printList(chunk);

			if (!chunk.isUsed)
			{
				auto toRemove = chunk;
				chunk = chunk.next;

				removeFromRemoveQueue(toRemove);
				removeChunk(toRemove);
			}
			else
			{
				auto c = chunk;
				chunk = chunk.next;
			}
		}
	}

	Chunk* createEmptyChunk(ivec3 coord)
	{
		return new Chunk(coord);
	}

	Chunk* getChunk(ivec3 coord)
	{
		return chunks.get(coord, null);
	}

	// Add already created chunk to storage
	// Sets up all adjacent
	void addChunk(Chunk* emptyChunk)
	{
		assert(emptyChunk);
		chunks[emptyChunk.coord] = emptyChunk;
		chunkObservers[emptyChunk.coord] = ChunkObserverList();
		ivec3 coord = emptyChunk.coord;

		void attachAdjacent(ubyte side)()
		{
			byte[3] offset = sideOffsets[side];
			ivec3 otherCoord = ivec3(cast(int)(coord.x + offset[0]),
												cast(int)(coord.y + offset[1]),
												cast(int)(coord.z + offset[2]));
			Chunk* other = getChunk(otherCoord);

			if (other !is null) 
				other.adjacent[oppSide[side]] = emptyChunk;
			emptyChunk.adjacent[side] = other;
		}

		// Attach all adjacent
		attachAdjacent!(0)();
		attachAdjacent!(1)();
		attachAdjacent!(2)();
		attachAdjacent!(3)();
		attachAdjacent!(4)();
		attachAdjacent!(5)();
	}

	void addToRemoveQueue(Chunk* chunk)
	{
		assert(chunk);
		assert(chunk !is null);

		// already queued
		if (chunk.next != null && chunk.prev != null) return;
		
		chunk.next = chunksToRemoveQueue;
		if (chunksToRemoveQueue) chunksToRemoveQueue.prev = chunk;
		chunksToRemoveQueue = chunk;
		++numChunksToRemove;
	}

	void removeFromRemoveQueue(Chunk* chunk)
	{
		assert(chunk);
		assert(chunk !is null);

		if (chunk.prev)
			chunk.prev.next = chunk.next;
		else
			chunksToRemoveQueue = chunk.next;

		if (chunk.next)
			chunk.next.prev = chunk.prev;

		chunk.next = null;
		chunk.prev = null;
		--numChunksToRemove;
	}

	void removeChunk(Chunk* chunk)
	{
		assert(chunk);
		assert(chunk !is null);

		assert(!chunk.isUsed);
		assert(chunkObservers.get(chunk.coord, ChunkObserverList.init).empty);

		void detachAdjacent(ubyte side)()
		{
			if (chunk.adjacent[side] !is null)
			{
				chunk.adjacent[side].adjacent[oppSide[side]] = null;
			}
			chunk.adjacent[side] = null;
		}

		// Detach all adjacent
		detachAdjacent!(0)();
		detachAdjacent!(1)();
		detachAdjacent!(2)();
		detachAdjacent!(3)();
		detachAdjacent!(4)();
		detachAdjacent!(5)();

		chunks.remove(chunk.coord);
		chunkObservers.remove(chunk.coord);

		if (chunk.mesh) chunk.mesh.free();
		delete chunk.mesh;
		version(Disk_Storage)
		{
			if (isChunkInWorldBounds(chunk.coord))
			{
				storeWorker.nextWorker.send(chunk.coord, cast(shared)chunk.data, true);
			}
		}
		else
		{
			delete chunk.data.typeData;
			delete chunk.data;
		}
		delete chunk;
	}

	// returns true if chunk is already loaded.
	bool loadChunk(ivec3 coord)
	{
		if (auto chunk = coord in chunks)
		{
			if ((*chunk).isMarkedForDeletion)
				removeFromRemoveQueue(*chunk);
			return (**chunk).isLoaded;
		}
		Chunk* chunk = createEmptyChunk(coord);
		addChunk(chunk);

		if (!isChunkInWorldBounds(coord)) return false;

		chunk.hasWriter = true;
		++numLoadChunkTasks;

		version(Disk_Storage)
			storeWorker.nextWorker.send(coord, genWorkers.nextWorker);
		else
			genWorkers.nextWorker.send(chunk.coord);

		return false;
	}

	bool isChunkInWorldBounds(ivec3 coord)
	{
		static if (BOUND_WORLD)
		{
			if(coord.x<0 || coord.y<0 || coord.z<0 || coord.x>=WORLD_SIZE ||
				coord.y>=WORLD_SIZE || coord.z>=WORLD_SIZE)
				return false;
		}

		return true;
	}
}