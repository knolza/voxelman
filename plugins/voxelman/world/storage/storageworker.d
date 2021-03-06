/**
Copyright: Copyright (c) 2014-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.world.storage.storageworker;

import std.experimental.logger;
import std.conv : to;
import std.datetime : MonoTime, Duration, usecs, dur, seconds;
import core.atomic;
import core.sync.condition;

import cbor;

import voxelman.block.utils;
import voxelman.world.gen.generators;
import voxelman.world.gen.utils;
import voxelman.core.config;
import voxelman.utils.compression;
import voxelman.utils.worker;
import voxelman.world.storage.chunk;
import voxelman.world.storage.chunkprovider;
import voxelman.world.storage.coordinates;
import voxelman.world.worlddb;


struct TimeMeasurer
{
	TimeMeasurer* nested;
	TimeMeasurer* next;
	MonoTime startTime;
	Duration takenTime;
	string taskName;
	bool wasRun = false;

	void reset()
	{
		wasRun = false;
		takenTime = Duration.zero;
		if (nested) nested.reset();
		if (next) next.reset();
	}

	void startTaskTiming(string name)
	{
		taskName = name;
		startTime = MonoTime.currTime;
	}

	void endTaskTiming()
	{
		wasRun = true;
		takenTime = MonoTime.currTime - startTime;
	}

	void printTime(bool isNested = false)
	{
		//int seconds; short msecs; short usecs;
		//takenTime.split!("seconds", "msecs", "usecs")(seconds, msecs, usecs);
		//if (msecs > 10 || seconds > 0 || isNested)
		//{
		//	if (wasRun)
		//		tracef("%s%s %s.%s,%ss", isNested?"  ":"", taskName, seconds, msecs, usecs);
		//	if (nested) nested.printTime(true);
		//	if (next) next.printTime(isNested);
		//}
	}
}

struct GenWorkerControl
{
	this(shared Worker[] genWorkers_)
	{
		genWorkers = genWorkers_;
		queueLengths.length = genWorkers.length;
	}

	shared Worker[] genWorkers;

	// last worker, we sent work to.
	size_t lastWorker;
	// last work item.
	ChunkWorldPos lastCwp;
	static struct QLen {size_t i; size_t len;}
	QLen[] queueLengths;

	// returns worker with smallest queue.
	size_t getWorker()
	{
		import std.algorithm : sort;
		foreach(i; 0..genWorkers.length)
		{
			queueLengths[i].i = i;
			queueLengths[i].len = genWorkers[i].taskQueue.length;
		}
		sort!((a,b) => a.len < b.len)(queueLengths);// balance worker queues
		return queueLengths[0].i;
	}

	// Sends chunks with the same x and z to the same worker.
	// There is thread local heightmap cache.
	void sendGenTask(ulong cwp)
	{
		auto _cwp = ChunkWorldPos(cwp);
		size_t workerIndex;
		// send task from the same chunk column
		// to the same worker to improve cache hit rate
		if (_cwp.x == lastCwp.x && _cwp.z == lastCwp.z)
		{
			workerIndex = lastWorker;
		}
		else
		{
			workerIndex = getWorker();
		}
		shared(Worker)* worker = &genWorkers[workerIndex];
		worker.taskQueue.pushItem!ulong(cwp);
		worker.taskQueue.pushItem(generators[_cwp.w % $]);
		worker.notify();
		lastWorker = workerIndex;
		lastCwp = _cwp;
	}
}

//version = DBG_OUT;
//version = DBG_COMPR;
void storageWorker(
			immutable WorldDb _worldDb,
			shared bool* workerRunning,
			shared Mutex workAvaliableMutex,
			shared Condition workAvaliable,
			shared SharedQueue* loadResQueue,
			shared SharedQueue* saveResQueue,
			shared SharedQueue* loadTaskQueue,
			shared SharedQueue* saveTaskQueue,
			shared Worker[] genWorkers,
			)
{
	version(DBG_OUT)infof("Storage worker started");
	infof("genWorkers.length %s", genWorkers.length);
	try
	{
	ubyte[] compressBuffer = new ubyte[](4096*16);
	ubyte[] buffer = new ubyte[](4096*16);
	WorldDb worldDb = cast(WorldDb)_worldDb;
	scope(exit) worldDb.close();

	TimeMeasurer taskTime;
	TimeMeasurer workTime;
	TimeMeasurer readTime;
	taskTime.nested = &readTime;
	readTime.next = &workTime;

	auto workerControl = GenWorkerControl(genWorkers);

	void writeChunk()
	{
		taskTime.reset();
		taskTime.startTaskTiming("WR");

		ChunkHeaderItem header = saveTaskQueue.popItem!ChunkHeaderItem();

		saveResQueue.startMessage();
		saveResQueue.pushMessagePart(header);
		try
		{
			size_t encodedSize = encodeCbor(buffer[], header.numLayers);

			foreach(_; 0..header.numLayers)
			{
				ChunkLayerItem layer = saveTaskQueue.popItem!ChunkLayerItem();

				encodedSize += encodeCbor(buffer[encodedSize..$], layer.timestamp);
				encodedSize += encodeCbor(buffer[encodedSize..$], layer.layerId);
				encodedSize += encodeCbor(buffer[encodedSize..$], layer.metadata);
				if (layer.type == StorageType.uniform)
				{
					encodedSize += encodeCbor(buffer[encodedSize..$], StorageType.uniform);
					encodedSize += encodeCbor(buffer[encodedSize..$], layer.uniformData);
					encodedSize += encodeCbor(buffer[encodedSize..$], layer.dataLength);
				}
				else if (layer.type == StorageType.fullArray)
				{
					encodedSize += encodeCbor(buffer[encodedSize..$], StorageType.compressedArray);
					ubyte[] compactBlocks = compressLayerData(layer.getArray!ubyte, compressBuffer);
					encodedSize += encodeCbor(buffer[encodedSize..$], compactBlocks);
					version(DBG_COMPR)infof("Store1 %s %s %s\n(%(%02x%))", header.cwp, compactBlocks.ptr, compactBlocks.length, cast(ubyte[])compactBlocks);
				}
				else if (layer.type == StorageType.compressedArray)
				{
					encodedSize += encodeCbor(buffer[encodedSize..$], StorageType.compressedArray);
					ubyte[] compactBlocks = layer.getArray!ubyte;
					encodedSize += encodeCbor(buffer[encodedSize..$], compactBlocks);
					version(DBG_COMPR)infof("Store2 %s %s %s\n(%(%02x%))", header.cwp, compactBlocks.ptr, compactBlocks.length, cast(ubyte[])compactBlocks);
				}

				saveResQueue.pushMessagePart(ChunkLayerTimestampItem(layer.timestamp, layer.layerId));
			}

			worldDb.putPerChunkValue(header.cwp.asUlong, buffer[0..encodedSize]);
		}
		catch(Exception e) errorf("storage exception %s", e.to!string);
		saveResQueue.endMessage();
		taskTime.endTaskTiming();
		taskTime.printTime();
		version(DBG_OUT)infof("task save %s", header.cwp);
	}

	void readChunk()
	{
		taskTime.reset();
		taskTime.startTaskTiming("RD");
		bool doGen;

		ulong cwp = loadTaskQueue.popItem!ulong();

		try
		{
			readTime.startTaskTiming("getPerChunkValue");
			ubyte[] cborData = worldDb.getPerChunkValue(cwp);
			readTime.endTaskTiming();
			//scope(exit) worldDb.perChunkSelectStmt.reset();

			if (cborData !is null)
			{
				workTime.startTaskTiming("decode");
				ubyte numLayers = decodeCborSingle!ubyte(cborData);
				// TODO check numLayers <= ubyte.max
				loadResQueue.startMessage();
				loadResQueue.pushMessagePart(ChunkHeaderItem(ChunkWorldPos(cwp), cast(ubyte)numLayers, 0));
				foreach(_; 0..numLayers)
				{
					auto timestamp = decodeCborSingle!TimestampType(cborData);
					auto layerId = decodeCborSingle!ubyte(cborData);
					auto metadata = decodeCborSingle!ushort(cborData);
					auto type = decodeCborSingle!StorageType(cborData);

					if (type == StorageType.uniform)
					{
						ulong uniformData = decodeCborSingle!ulong(cborData);
						auto dataLength = decodeCborSingle!LayerDataLenType(cborData);
						loadResQueue.pushMessagePart(ChunkLayerItem(StorageType.uniform, layerId, dataLength, timestamp, uniformData, metadata));
					}
					else
					{
						import core.memory : GC;
						assert(type == StorageType.compressedArray);
						ubyte[] compactBlocks = decodeCborSingle!(ubyte[])(cborData);
						compactBlocks = compactBlocks.dup;
						LayerDataLenType dataLength = cast(LayerDataLenType)compactBlocks.length;
						ubyte* data = cast(ubyte*)compactBlocks.ptr;

						// Add root to data.
						// Data can be collected by GC if no-one is referencing it.
						// It is needed to pass array trough shared queue.
						GC.addRoot(data); // TODO remove when moved to non-GC allocator
						version(DBG_COMPR)infof("Load %s L %s C (%(%02x%))", ChunkWorldPos(cwp), compactBlocks.length, cast(ubyte[])compactBlocks);
						loadResQueue.pushMessagePart(ChunkLayerItem(StorageType.compressedArray, layerId, dataLength, timestamp, data, metadata));
					}
				}
				loadResQueue.endMessage();
				// if (cborData.length > 0) error; TODO
				workTime.endTaskTiming();
			}
			else doGen = true;
		}
		catch(Exception e) {
			infof("storage exception %s regenerating %s", e.to!string, ChunkWorldPos(cwp));
			doGen = true;
		}
		if (doGen) {
			workerControl.sendGenTask(cwp);
		}
		taskTime.endTaskTiming();
		taskTime.printTime();
		version(DBG_OUT)infof("task load %s", ChunkWorldPos(cwp));
	}

	uint numReceived;
	MonoTime frameStart = MonoTime.currTime;
	size_t prevReceived = size_t.max;
	while (*atomicLoad!(MemoryOrder.acq)(workerRunning))
	{
		synchronized (workAvaliableMutex)
		{
			(cast(Condition)workAvaliable).wait();
		}

		worldDb.beginTxn();
		while (!loadTaskQueue.empty)
		{
			readChunk();
			++numReceived;
		}
		worldDb.abortTxn();

		worldDb.beginTxn();
		while (!saveTaskQueue.empty)
		{
			auto type = saveTaskQueue.popItem!SaveItemType();
			final switch(type) {
				case SaveItemType.chunk:
					writeChunk();
					++numReceived;
					break;
				case SaveItemType.saveHandler:
					IoHandler ioHandler = saveTaskQueue.popItem!IoHandler();
					ioHandler(worldDb);
					break;
			}
		}
		worldDb.commitTxn();

		if (prevReceived != numReceived)
			version(DBG_OUT)infof("Storage worker running %s %s", numReceived, *atomicLoad(workerRunning));
		prevReceived = numReceived;

		auto now = MonoTime.currTime;
		auto dur = now - frameStart;
		if (dur > 3.seconds) {
			//infof("Storage update");
			frameStart = now;
		}
	}
	}
	catch(Throwable t)
	{
		infof("%s from storage worker", t.to!string);
		throw t;
	}
	version(DBG_OUT)infof("Storage worker stopped (%s, %s)", numReceived, *atomicLoad(workerRunning));
}
