/**
Copyright: Copyright (c) 2013-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.world.storage.chunk;

import std.experimental.logger;
import std.array : uninitializedArray;
import std.string : format;
import std.typecons : Nullable;

import cbor;
import voxelman.math;
import voxelman.geometry.box;

import voxelman.core.config;
import voxelman.block.utils;
import voxelman.core.chunkmesh;
import voxelman.world.storage.coordinates;
import voxelman.world.storage.utils;
import voxelman.utils.compression;

enum FIRST_LAYER = 0;
enum ENTITY_LAYER = 1;
enum BLOCKS_DATA_LENGTH = CHUNK_SIZE_CUBE * BlockId.sizeof;
enum BLOCKID_UNIFORM_FILL_BITS = bitsToUniformLength(BlockId.sizeof * 8);


ubyte bitsToUniformLength(ubyte bits) {
	if (bits == 1)
		return 1;
	else if (bits == 2)
		return 2;
	else if (bits == 4)
		return 3;
	else if (bits == 8)
		return 4;
	else if (bits == 16)
		return 5;
	else if (bits == 32)
		return 6;
	else if (bits == 64)
		return 7;
	else
		assert(false);
}

/// is used as array size when non-uniform.
/// Used to allocate full array when uniform.
/// Assumes array length as CHUNK_SIZE_CUBE, but element size is dataLength/CHUNK_SIZE_CUBE if CHUNK_SIZE_CUBE > dataLength
/// Or CHUNK_SIZE_CUBE/dataLength otherwise. Element size is used to fill created array.
/// If dataLength < CHUNK_SIZE_CUBE then element size is less than byte.
/// Element size must be power of two, either of bytes or of bits.
alias LayerDataLenType = uint;

enum StorageType : ubyte
{
	uniform,
	//linearMap,
	//hashMap,
	compressedArray,
	fullArray,
}

ubyte[] allocLayerArray(size_t length) {
	return uninitializedArray!(ubyte[])(length);
}

void freeLayerArray(Layer)(ref Layer layer) {
	import core.memory : GC;
	assert(layer.type != StorageType.uniform);
	GC.free(layer.dataPtr);
	layer.dataPtr = null;
	layer.dataLength = 0;
}

struct ChunkHeaderItem {
	ChunkWorldPos cwp;
	uint numLayers;
	uint metadata; // for task purposes
}
static assert(ChunkHeaderItem.sizeof == 16);

struct ChunkLayerTimestampItem {
	uint timestamp;
	ubyte layerId;
}
static assert(ChunkLayerTimestampItem.sizeof == 8);

/// Stores layer of chunk data. Used for transferring and saving chunk layers.
/// Stores layerId. Stores no user count.
align(1)
struct ChunkLayerItem
{
	StorageType type;
	ubyte layerId;
	ushort metadata;
	uint timestamp;
	union {
		ulong uniformData;
		void* dataPtr; /// Stores ptr to the first byte of data. The length of data is in dataLength.
	}

	LayerDataLenType dataLength;
	this(StorageType _type, ubyte _layerId, LayerDataLenType _dataLength, uint _timestamp, ulong _uniformData, ushort _metadata = 0) {
		type = _type; layerId = _layerId; dataLength = _dataLength; timestamp = _timestamp; uniformData = _uniformData; metadata = _metadata;
	}
	this(StorageType _type, ubyte _layerId, LayerDataLenType _dataLength, uint _timestamp, ubyte* _dataPtr, ushort _metadata = 0) {
		type = _type; layerId = _layerId; dataLength = _dataLength; timestamp = _timestamp; dataPtr = _dataPtr; metadata = _metadata;
	}
	this(T)(StorageType _type, ubyte _layerId, uint _timestamp, T[] _array, ushort _metadata = 0) {
		ubyte[] data = cast(ubyte[])_array;
		type = _type; layerId = _layerId; dataLength = cast(LayerDataLenType)data.length; timestamp = _timestamp; dataPtr = cast(void*)data.ptr; metadata = _metadata;
	}
	this(ChunkLayerSnap l, ubyte _layerId) {
		type = l.type;
		layerId = _layerId;
		dataLength = l.dataLength;
		timestamp = l.timestamp;
		uniformData = l.uniformData;
		metadata = l.metadata;
	}

	void toString()(scope void delegate(const(char)[]) sink) const
	{
		import std.format : formattedWrite;
		sink.formattedWrite("ChunkLayerItem(%s, %s, %s, %s, {%s, %s}, %s)",
			type, layerId, dataLength, timestamp, uniformData, dataPtr, metadata);
	}
}
static assert(ChunkLayerItem.sizeof == 20);

struct WriteBuffer
{
	ChunkLayerItem layer;
	bool isModified = true;

	this(Layer)(Layer _layer) if (isSomeLayer!Layer) {
		if (_layer.type == StorageType.uniform) {
			makeUniform(_layer.uniformData, _layer.dataLength, _layer.metadata);
		} else {
			applyLayer(_layer, layer);
		}
	}

	void makeUniform(ulong uniformData, LayerDataLenType dataLength, ushort metadata = 0) {
		if (!isUniform) {
			freeLayerArray(layer);
		}
		layer.uniformData = uniformData;
		layer.dataLength = dataLength;
		layer.metadata = metadata;
	}

	void makeUniform(T)(ulong uniformData, ushort metadata = 0) {
		if (!isUniform) {
			freeLayerArray(layer);
		}
		layer.uniformData = uniformData;
		layer.dataLength = bitsToUniformLength(T.sizeof * 8);
		layer.metadata = metadata;
	}

	bool isUniform() {
		return layer.type == StorageType.uniform;
	}

	T getUniform(T)() {
		return layer.getUniform!T;
	}

	T[] getArray(T)() {
		return layer.getArray!T;
	}
}

void applyLayer(Layer1, Layer2)(const Layer1 layer, ref Layer2 writeBuffer)
	if (isSomeLayer!Layer1 && isSomeLayer!Layer2)
{
	ubyte[] buffer;
	if (layer.type == StorageType.uniform)
	{
		// zero is used to denote that uniform cannot be expanded and should produce empty array.
		assert(layer.dataLength >= 0 && layer.dataLength <= 7,
			format("dataLength == %s", layer.dataLength));
		if (layer.dataLength > 0)
		{
			size_t itemBitsPowerOfTwo = layer.dataLength - 1; // [1; 7] => [0; 6]
			size_t itemBits = 1 << itemBitsPowerOfTwo; // [1..64]
			size_t arraySize = (CHUNK_SIZE_CUBE * itemBits) / 8;

			buffer = ensureLayerArrayLength(writeBuffer, arraySize);
			expandUniform(buffer, cast(ubyte)itemBits, layer.uniformData);
		}
		else
		{
			// empty array
		}
	}
	else if (layer.type == StorageType.fullArray)
	{
		buffer = ensureLayerArrayLength(writeBuffer, layer.dataLength);
		buffer[] = layer.getArray!ubyte;
	}
	else if (layer.type == StorageType.compressedArray)
	{
		ubyte[] compressedData = layer.getArray!ubyte;
		size_t uncompressedLength = uncompressedDataLength(compressedData);
		buffer = ensureLayerArrayLength(writeBuffer, uncompressedLength);
		ubyte[] decompressedData = decompress(compressedData, buffer);
		assert(decompressedData.length == buffer.length);
	}
	writeBuffer.type = StorageType.fullArray;
	writeBuffer.metadata = layer.metadata;
	writeBuffer.dataPtr = buffer.ptr;
	writeBuffer.dataLength = cast(LayerDataLenType)buffer.length;
}

ubyte[] ensureLayerArrayLength(Layer)(ref Layer layer, size_t length)
	if (isSomeLayer!Layer)
{
	ubyte[] buffer;
	if (layer.isUniform)
	{
		buffer = allocLayerArray(length);
	}
	else
	{
		if (layer.dataLength == length)
		{
			buffer = layer.getArray!ubyte;
		}
		else
		{
			freeLayerArray(layer); // TODO realloc
			buffer = allocLayerArray(length);
		}
	}
	return buffer;
}

// tables of repeated bit patterns for 1, 2 and 4 bit items.
private static immutable ubyte[2] bitsTable1 = [0b0000_0000, 0b1111_1111];
private static immutable ubyte[4] bitsTable2 = [0b00_00_00_00, 0b01_01_01_01, 0b10_10_10_10, 0b11_11_11_11];
private static immutable ubyte[16] bitsTable4 = [
0b0000_0000, 0b0001_0001, 0b0010_0010, 0b0011_0011, 0b0100_0100, 0b0101_0101, 0b0110_0110, 0b0111_0111,
0b1000_1000, 0b1001_1001, 0b1010_1010, 0b1011_1011, 0b1100_1100, 0b1101_1101, 0b1110_1110, 0b1111_1111];

void expandUniform(ubyte[] buffer, ubyte itemBits, ulong uniformData)
{
	switch(itemBits) {
		case 1:
			ubyte byteFiller = bitsTable1[uniformData & 0b0001];
			buffer[] = byteFiller;
			break;
		case 2:
			ubyte byteFiller = bitsTable2[uniformData & 0b0011];
			buffer[] = byteFiller;
			break;
		case 4:
			ubyte byteFiller = bitsTable4[uniformData & 0b1111];
			buffer[] = byteFiller;
			break;
		case 8:
			ubyte byteFiller = uniformData & ubyte.max;
			buffer[] = byteFiller;
			break;
		case 16:
			ushort ushortFiller = uniformData & ushort.max;
			(cast(ushort[])buffer)[] = ushortFiller;
			break;
		case 32:
			uint uintFiller = uniformData & uint.max;
			(cast(uint[])buffer)[] = uintFiller;
			break;
		case 64:
			ulong ulongFiller = uniformData & ulong.max;
			(cast(ulong[])buffer)[] = ulongFiller;
			break;
		default:
			assert(false, "Invalid itemBits");
	}
}

/// Container for chunk updates
/// If blockChanges is null uses newBlockData
struct ChunkChange
{
	uvec3 a, b; // box
	BlockId blockId;
}

// container of single block change.
// position is chunk local [0; CHUNK_SIZE-1];
struct BlockChange
{
	ushort index;
	BlockId blockId;
}

ushort[2] areaOfImpact(BlockChange[] changes)
{
	ushort start;
	ushort end;

	foreach(change; changes)
	{
		if (change.index < start)
			start = change.index;
		if (change.index > end)
			end = change.index;
	}

	return cast(ushort[2])[start, end+1];
}

// stores all used snapshots of the chunk.
struct BlockDataSnapshot
{
	BlockData blockData;
	TimestampType timestamp;
	uint numUsers;
}

/// Stores layer of chunk data. Blocks are stored as array of blocks or uniform.
struct ChunkLayerSnap
{
	union {
		ulong uniformData;
		void* dataPtr; /// Stores ptr to the first byte of data. The length of data is in dataLength.
	}
	LayerDataLenType dataLength; // unused when uniform
	uint timestamp;
	ushort numUsers;
	ushort metadata;
	StorageType type;
	this(StorageType _type, LayerDataLenType _dataLength, uint _timestamp, ulong _uniformData, ushort _metadata = 0) {
		type = _type; dataLength = _dataLength; timestamp = _timestamp; uniformData = _uniformData; metadata = _metadata;
	}
	this(StorageType _type, LayerDataLenType _dataLength, uint _timestamp, void* _dataPtr, ushort _metadata = 0) {
		type = _type; dataLength = _dataLength; timestamp = _timestamp; dataPtr = _dataPtr; metadata = _metadata;
	}
	this(T)(StorageType _type, uint _timestamp, T[] _array, ushort _metadata = 0) {
		ubyte[] data = cast(ubyte[])_array;
		type = _type; dataLength = cast(LayerDataLenType)data.length; timestamp = _timestamp; dataPtr = data.ptr; metadata = _metadata;
	}
	this(ChunkLayerItem l) {
		numUsers = 0;
		timestamp = l.timestamp;
		type = l.type;
		dataLength = l.dataLength;
		uniformData = l.uniformData;
		metadata = l.metadata;
	}
}

enum isSomeLayer(Layer) = is(Layer == ChunkLayerSnap) || is(Layer == ChunkLayerItem) || is(Layer == Nullable!ChunkLayerSnap);

T[] getArray(T, Layer)(const ref Layer layer)
	if (isSomeLayer!Layer)
{
	assert(layer.type != StorageType.uniform);
	return cast(T[])(layer.dataPtr[0..layer.dataLength]);
}
T getUniform(T, Layer)(const ref Layer layer)
	if (isSomeLayer!Layer)
{
	assert(layer.type == StorageType.uniform);
	return cast(T)layer.uniformData;
}

BlockId getBlockId(Layer)(const ref Layer layer, BlockChunkIndex index)
	if (isSomeLayer!Layer)
{
	if (layer.type == StorageType.uniform) return layer.getUniform!BlockId;
	if (layer.type == StorageType.compressedArray) {
		BlockId[CHUNK_SIZE_CUBE] buffer;
		decompressLayerData(layer, cast(ubyte[])buffer[]);
		return buffer[index];
	}
	return getArray!BlockId(layer)[index];
}

BlockId getBlockId(Layer)(const ref Layer layer, int x, int y, int z)
	if (isSomeLayer!Layer)
{
	return getBlockId(layer, BlockChunkIndex(x, y, z));
}

bool isUniform(Layer)(const ref Layer layer) @property
	if (isSomeLayer!Layer)
{
	return layer.type == StorageType.uniform;
}

BlockData toBlockData(Layer)(const ref Layer layer, ubyte layerId)
	if (isSomeLayer!Layer)
{
	BlockData res;
	res.uniform = layer.type == StorageType.uniform;
	res.metadata = layer.metadata;
	res.layerId = layerId;
	if (!res.uniform) {
		res.blocks = layer.getArray!ubyte();
	} else {
		res.uniformType = layer.uniformData;
		res.dataLength = layer.dataLength;
	}
	return res;
}

ChunkLayerItem fromBlockData(const ref BlockData bd)
{
	if (bd.uniform)
		return ChunkLayerItem(StorageType.uniform, bd.layerId, bd.dataLength, 0, bd.uniformType, bd.metadata);
	else
		return ChunkLayerItem(StorageType.fullArray, bd.layerId, 0, bd.blocks, bd.metadata);
}

void copyToBuffer(Layer)(Layer layer, BlockId[] outBuffer)
	if (isSomeLayer!Layer)
{
	assert(outBuffer.length == CHUNK_SIZE_CUBE);
	if (layer.type == StorageType.uniform)
		outBuffer[] = cast(BlockId)layer.uniformData;
	else if (layer.type == StorageType.fullArray)
		outBuffer[] = layer.getArray!BlockId;
	else if (layer.type == StorageType.compressedArray)
		decompressLayerData(layer, outBuffer);
}

size_t getLayerDataBytes(Layer)(const ref Layer layer)
	if (isSomeLayer!Layer)
{
	if (layer.type == StorageType.uniform)
		return 0;
	else
		return layer.dataLength;
}

void applyChanges(WriteBuffer* writeBuffer, BlockChange[] changes)
{
	assert(!writeBuffer.isUniform);
	assert(writeBuffer.layer.dataLength == BLOCKS_DATA_LENGTH);
	BlockId[] blocks = writeBuffer.layer.getArray!BlockId;
	foreach(change; changes)
	{
		blocks[change.index] = change.blockId;
	}
}

void applyChanges(WriteBuffer* writeBuffer, ChunkChange[] changes)
{
	assert(!writeBuffer.isUniform);
	assert(writeBuffer.layer.dataLength == BLOCKS_DATA_LENGTH);
	BlockId[] blocks = writeBuffer.layer.getArray!BlockId;
	foreach(change; changes)
	{
		setSubArray(blocks, Box(ivec3(change.a), ivec3(change.b)), change.blockId);
	}
}

void setSubArray(BlockId[] buffer, Box box, BlockId blockId)
{
	assert(buffer.length == CHUNK_SIZE_CUBE);

	if (box.position.x == 0 && box.size.x == CHUNK_SIZE)
	{
		if (box.position.z == 0 && box.size.z == CHUNK_SIZE)
		{
			if (box.position.y == 0 && box.size.y == CHUNK_SIZE)
			{
				buffer[] = blockId;
			}
			else
			{
				auto from = box.position.y * CHUNK_SIZE_SQR;
				auto to = (box.position.y + box.size.y) * CHUNK_SIZE_SQR;
				buffer[from..to] = blockId;
			}
		}
		else
		{
			foreach(y; box.position.y..(box.position.y + box.size.y))
			{
				auto from = y * CHUNK_SIZE_SQR + box.position.z * CHUNK_SIZE;
				auto to = y * CHUNK_SIZE_SQR + (box.position.z + box.size.z) * CHUNK_SIZE;
				buffer[from..to] = blockId;
			}
		}
	}
	else
	{
		int posx = box.position.x;
		int endx = box.position.x + box.size.x;
		int endy = box.position.y + box.size.y;
		int endz = box.position.z + box.size.z;
		foreach(y; box.position.y..endy)
		foreach(z; box.position.z..endz)
		{
			auto offset = y * CHUNK_SIZE_SQR + z * CHUNK_SIZE;
			auto from = posx + offset;
			auto to = endx + offset;
			buffer[from..to] = blockId;
		}
	}
}

ubyte[] compressLayerData(ubyte[] data, ubyte[] buffer)
{
	size_t size = encodeCbor(buffer[], data.length);
	size += compress(data, buffer[size..$]).length;
	return buffer[0..size];
}

ubyte[] decompressLayerData(Layer)(const Layer layer, ubyte[] outBuffer) if (isSomeLayer!Layer)
{
	assert(layer.type == StorageType.compressedArray);
	return decompressLayerData(layer.getArray!ubyte, outBuffer);
}

ubyte[] decompressLayerData(const ubyte[] _compressedData)
{
	ubyte[] compressedData = cast(ubyte[])_compressedData;
	auto dataSize = decodeCborSingle!size_t(compressedData);
	ubyte[] buffer = uninitializedArray!(ubyte[])(dataSize);
	ubyte[] decompressedData = decompress(compressedData, buffer);
	return decompressedData;
}

// pops and returns size of uncompressed data. Modifies provided array.
size_t uncompressedDataLength()(auto ref ubyte[] compressedData)
{
	return decodeCborSingle!size_t(compressedData);
}

ubyte[] decompressLayerData(const ubyte[] _compressedData, ubyte[] outBuffer)
{
	ubyte[] compressedData = cast(ubyte[])_compressedData;
	auto dataSize = decodeCborSingle!size_t(compressedData);
	//assert(outBuffer.length == dataSize, format("%s != %s", outBuffer.length, dataSize));
	ubyte[] decompressedData = decompress(compressedData, outBuffer);
	return decompressedData;
}

// Stores blocks of the chunk.
struct BlockData
{
	void validate()
	{
		if (layerId == 0 && !uniform && blocks.length != BLOCKS_DATA_LENGTH) {
			fatalf("Size of uniform chunk != CHUNK_SIZE_CUBE, == %s", blocks.length);
		}
	}

	/// null if uniform is true, or contains chunk data otherwise
	ubyte[] blocks;

	/// type of common block
	ulong uniformType = 0; // Unknown block

	/// is chunk filled with block of the same type
	bool uniform = true;
	uint dataLength;

	ushort metadata;
	ubyte layerId;
}
