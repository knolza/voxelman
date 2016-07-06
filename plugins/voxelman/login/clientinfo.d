/**
Copyright: Copyright (c) 2015-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.login.clientinfo;

import dlib.math.vector : vec3, vec2;

import voxelman.core.config;
import voxelman.world.storage.worldbox : WorldBox;
import voxelman.world.storage.coordinates;

struct ClientInfo
{
	size_t id;
	string name;
	vec3 pos = START_POS;
	vec2 heading = vec2(-90, 0);
	DimentionId dimention;

	int viewRadius = DEFAULT_VIEW_RADIUS;
	WorldBox visibleBox;

	bool isLoggedIn;
	bool isSpawned;

	ChunkWorldPos chunk() {
		ChunkWorldPos cwp = BlockWorldPos(pos, dimention);
		return cwp;
	}
}
