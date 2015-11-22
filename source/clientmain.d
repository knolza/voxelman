/**
Copyright: Copyright (c) 2015 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module clientmain;

import std.file : mkdirRecurse;

import voxelman.utils.log;
import pluginlib.pluginregistry;

void main(string[] args)
{
	mkdirRecurse("../logs");
	setupLogger("../logs/client.log");
	pluginRegistry.clientMain(args);
}
