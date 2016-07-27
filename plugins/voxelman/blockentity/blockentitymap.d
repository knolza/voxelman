/**
Copyright: Copyright (c) 2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.blockentity.blockentitymap;

import std.experimental.logger;
import std.stdio;
import std.string;

T nextPOT(T)(T x) {
	--x;
	x |= x >> 1;
	x |= x >> 2;
	x |= x >> 4;
	static if (T.sizeof >= 16) x |= x >>  8;
	static if (T.sizeof >= 32) x |= x >> 16;
	static if (T.sizeof >= 64) x |= x >> 32;
	++x;

	return x;
}

unittest {
	assert(nextPOT(1) == 1);
	assert(nextPOT(2) == 2);
	assert(nextPOT(3) == 4);
	assert(nextPOT(4) == 4);
	assert(nextPOT(5) == 8);
	assert(nextPOT(10) == 16);
	assert(nextPOT(30) == 32);
	assert(nextPOT(250) == 256);
	assert(nextPOT(1<<15+1) == 1<<16);
	assert(nextPOT(1UL<<31+1) == 1UL<<32);
	assert(nextPOT(1UL<<49+1) == 1UL<<50);
}

struct BlockEntityMap
{
	import std.experimental.allocator.gc_allocator;
	import std.experimental.allocator.mallocator;

	alias Key = ushort;
	alias Value = ulong;
	Key[] keys;
	Value[] values;
	size_t length;

	private bool resizing;
	enum nullKey = ushort.max;

	//alias allocator = Mallocator.instance;
	alias allocator = GCAllocator.instance;

	this(ubyte[] array, ushort length) {
		if (array.length % (Key.sizeof + Value.sizeof))
			writefln("size %s", array.length);
		size_t size = array.length / (Key.sizeof + Value.sizeof);
		keys = cast(Key[])array[0..Key.sizeof * size];
		values = cast(Value[])array[Key.sizeof * size..$];
		this.length = length;
	}

	ubyte[] getTable() {
		return (cast(ubyte[])keys).ptr[0..(Key.sizeof + Value.sizeof) * keys.length];
	}

	@property size_t capacity() const { return keys.length; }

	void remove(ushort key) {
		auto idx = findIndex(key);
		if (idx == size_t.max) return;
		auto i = idx;
		while (true)
		{
			keys[i] = nullKey;

			size_t j = i, r;
			do {
				if (++i >= keys.length) i -= keys.length;
				if (keys[i] == nullKey)
				{
					--length;
					return;
				}
				r = keys[i] & (keys.length-1);
			}
			while ((j<r && r<=i) || (i<j && j<r) || (r<=i && i<j));
			keys[j] = keys[i];
			values[j] = values[i];
		}
	}

	Value get(ushort key, Value default_value = Value.init) {
		auto idx = findIndex(key);
		if (idx == size_t.max) return default_value;
		return values[idx];
	}

	void clear() {
		keys[] = nullKey;
		length = 0;
	}

	void opIndexAssign(Value value, ushort key) {
		grow(1);
		auto i = findInsertIndex(key);
		if (keys[i] != key) ++length;
		//writefln("index %s for %s %016b len %s", i, key, key, length);
		//writefln("replace %s:%s by %s:%s", keys[i], values[i], key, value);
		keys[i] = key;
		values[i] = value;
	}

	ref inout(Value) opIndex(ushort key) inout {
		auto idx = findIndex(key);
		assert (idx != size_t.max, "Accessing non-existent key.");
		return values[idx];
	}

	inout(Value)* opBinaryRight(string op)(ushort key) inout if (op == "in") {
		auto idx = findIndex(key);
		if (idx == size_t.max) return null;
		return &values[idx];
	}

	int opApply(int delegate(ref Value) del) {
		foreach (i; 0 .. keys.length)
			if (keys[i] != nullKey)
				if (auto ret = del(values[i]))
					return ret;
		return 0;
	}

	int opApply(int delegate(in ref Value) del) const {
		foreach (i; 0 .. keys.length)
			if (keys[i] != nullKey)
				if (auto ret = del(values[i]))
					return ret;
		return 0;
	}

	int opApply(int delegate(in ref ushort, ref Value) del) {
		foreach (i; 0 .. keys.length)
			if (keys[i] != nullKey)
				if (auto ret = del(keys[i], values[i]))
					return ret;
		return 0;
	}

	int opApply(int delegate(in ref ushort, in ref Value) del) const {
		foreach (i; 0 .. keys.length)
			if (keys[i] != nullKey)
				if (auto ret = del(keys[i], values[i]))
					return ret;
		return 0;
	}

	void reserve(size_t amount) {
		auto newcap = ((length + amount) * 3) / 2;
		resize(newcap);
	}

	void shrink() {
		auto newcap = length * 3 / 2;
		resize(newcap);
	}

	void printStats() {
		writefln("cap %s len %s", capacity, length);
	}

	private size_t findIndex(ushort key) const {
		if (length == 0) return size_t.max;
		size_t start = key & (keys.length-1);
		auto i = start;
		while (keys[i] != key) {
			if (keys[i] == nullKey) return size_t.max;
			if (++i >= keys.length) i -= keys.length;
			if (i == start) return size_t.max;
		}
		return i;
	}

	private size_t findInsertIndex(ushort key) const {
		size_t target = key & (keys.length-1);
		auto i = target;
		while (keys[i] != nullKey && keys[i] != key) {
			if (++i >= keys.length) i -= keys.length;
			assert (i != target, "No free bucket found, HashMap full!?");
		}
		return i;
	}

	private void grow(size_t amount) {
		auto newsize = length + amount;
		if (newsize < (keys.length*2)/3) return;
		auto newcap = keys.length ? keys.length : 1;
		while (newsize >= (newcap*2)/3) newcap *= 2;
		resize(newcap);
	}

	private void resize(size_t newSize)
	{
		assert(!resizing);
		resizing = true;
		scope(exit) resizing = false;

		newSize = nextPOT(newSize);

		auto oldKeys = keys;
		auto oldValues = values;

		if (newSize) {
			void[] array = allocator.allocate((Key.sizeof + Value.sizeof) * newSize);
			keys = cast(Key[])(array[0..Key.sizeof * newSize]);
			values = cast(Value[])(array[Key.sizeof * newSize..$]);
			//infof("%s %s %s", array.length, keys.length, values.length);
			keys[] = nullKey;
			foreach (i, ref key; oldKeys) {
				if (key != nullKey) {
					auto idx = findInsertIndex(key);
					keys[idx] = key;
					values[idx] = oldValues[i];
				}
			}
		} else {
			keys = null;
			values = null;
		}

		if (oldKeys) {
			void[] arr = (cast(void[])oldKeys).ptr[0..(Key.sizeof + Value.sizeof) * newSize];
			allocator.deallocate(arr);
		}
	}

	void toString()(scope void delegate(const(char)[]) sink)
	{
		import std.format : formattedWrite;
		sink.formattedWrite("[",);
		foreach(key, value; this)
		{
			sink.formattedWrite("%s:%s, ", key, value);
		}
		sink.formattedWrite("]");
	}
}

/*
unittest {
	BlockEntityMap map;

	foreach (ushort i; 0 .. 100) {
		map[i] = i;
		assert(map.length == i+1);
	}
	map.printStats();

	foreach (ushort i; 0 .. 100) {
		auto pe = i in map;
		assert(pe !is null && *pe == i);
		assert(map[i] == i);
	}
	map.printStats();

	foreach (ushort i; 0 .. 50) {
		map.remove(i);
		assert(map.length == 100-i-1);
	}
	map.shrink();
	map.printStats();

	foreach (ushort i; 50 .. 100) {
		auto pe = i in map;
		assert(pe !is null && *pe == i);
		assert(map[i] == i);
	}
	map.printStats();

	foreach (ushort i; 50 .. 100) {
		map.remove(i);
		assert(map.length == 100-i-1);
	}
	map.printStats();
	map.shrink();
	map.printStats();
	map.reserve(100);
	map.printStats();
}*/

unittest {
	ushort[] keys = [140,268,396,524,652,780,908,28,156,284,
		412,540,668,796,924,920,792,664,536,408,280,152,24];
	BlockEntityMap map;
	foreach (i, ushort key; keys) {
		//writefln("set1 %s %s", map, map.length);
		map[key] = key;
		//writefln("set2 %s %s", map, map.length);
		assert(map.length == i+1, format("%s %s", i+1, map.length));
		assert(key in map && map[key] == key);
		assert(map.get(key, 0) == key);
	}
}
