/**
Copyright: Copyright (c) 2015-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module voxelman.math.utils;

import std.traits : isFloatingPoint;
import voxelman.math;

void nansToZero(T, int size)(ref Vector!(T, size) vector)
	if (isFloatingPoint!T)
{
	foreach(ref item; vector.arrayof)
	{
		item = isNaN(item) ? 0 : item;
	}
}

void nansToZero(T, int size)(ref T[size] vector)
	if (isFloatingPoint!T)
{
	foreach(ref item; vector)
	{
		item = isNaN(item) ? 0 : item;
	}
}

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
