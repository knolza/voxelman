/**
Copyright: Copyright (c) 2015 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module voxelman.clientmain;

import std.file : mkdirRecurse;

import voxelman.utils.log;
import voxelman.client.clientplugin;
import anchovy.gui;

void main(string[] args)
{
	// BUG test
	//import dlib.geometry.frustum;
	//Frustum f;
	//Frustum f2;
	//f2 = f;

	mkdirRecurse("../logs");
	setupLogger("../logs/client.log");
	auto clientPlugin = new ClientPlugin();
	clientPlugin.run(args);
	//auto app = new ClientApp(uvec2(1280, 720), "Voxelman client");
}
