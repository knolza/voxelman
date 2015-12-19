/**
Copyright: Copyright (c) 2015 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.storage.chunkprovider;

import core.thread : thread_joinAll;
import std.concurrency : Tid, thisTid, send, receiveTimeout;
import std.datetime : msecs;
import std.experimental.logger;

import dlib.math.vector;

import voxelman.core.chunkgen;
import voxelman.core.config;
import voxelman.storage.chunk;
import voxelman.storage.chunkstorage;
import voxelman.storage.coordinates;
import voxelman.storage.storageworker;
import voxelman.storage.world;
import voxelman.utils.workergroup;


struct SnapshotLoadedMessage
{
	ChunkWorldPos cwp;
	BlockDataSnapshot snapshot;
}

struct SnapshotSavedMessage
{
	ChunkWorldPos cwp;
	BlockDataSnapshot snapshot;
}

struct LoadSnapshotMessage
{
	ChunkWorldPos cwp;
	BlockType[] blockBuffer;
	Tid genWorker;
}

struct SaveSnapshotMessage
{
	ChunkWorldPos cwp;
	BlockDataSnapshot snapshot;
}

struct ChunkProvider
{
private:
	WorkerGroup!(chunkGenWorkerThread) genWorkers;
	WorkerGroup!(storageWorkerThread) storeWorker;

public:
	void delegate(ChunkWorldPos, BlockDataSnapshot)[] onChunkLoadedHandlers;
	void delegate(ChunkWorldPos, TimestampType)[] onChunkSavedHandlers;
	size_t loadQueueLength;

	size_t loadQueueSpaceAvaliable() @property const
	{
		return MAX_LOAD_QUEUE_LENGTH - loadQueueLength;
	}

	void init(string worldDir, uint numWorkers)
	{
		genWorkers.startWorkers(numWorkers, thisTid);
		storeWorker.startWorkers(1, thisTid, worldDir~"/regions");
	}

	void stop()
	{
		genWorkers.stopWorkers();
		storeWorker.stopWorkersWhenDone();
	}

	void update()
	{
		bool message = true;
		while (message)
		{
			message = receiveTimeout(0.msecs,
				(immutable(SnapshotLoadedMessage)* message) {
					auto m = cast(SnapshotLoadedMessage*)message;
					--loadQueueLength;
					foreach(handler; onChunkLoadedHandlers)
						handler(m.cwp, m.snapshot);
				},
				(immutable(SnapshotSavedMessage)* message) {
					auto m = cast(SnapshotSavedMessage*)message;
					foreach(handler; onChunkSavedHandlers)
						handler(m.cwp, m.snapshot.timestamp);
				}
			);
		}
	}

	void loadChunk(ChunkWorldPos cwp, BlockType[] blockBuffer) {
		auto m = new LoadSnapshotMessage(cwp, blockBuffer, genWorkers.nextWorker);
		storeWorker.nextWorker.send(cast(immutable(LoadSnapshotMessage)*)m);
		++loadQueueLength;
	}

	void saveChunk(ChunkWorldPos cwp, BlockDataSnapshot snapshot) {
		auto m = new SaveSnapshotMessage(cwp, snapshot);
		storeWorker.nextWorker.send(cast(immutable(SaveSnapshotMessage)*)m);
	}
}