module exampleplugin.client;

import std.experimental.logger;
import pluginlib;

shared static this()
{
	pluginRegistry.regClientPlugin(new ExamplePluginClient);
}

class ExamplePluginClient : IPlugin
{
	mixin IdAndSemverFrom!(exampleplugin.plugininfo);

	override void registerResourceManagers(void delegate(IResourceManager) registerHandler)
	{
		infof("%s registerResourceManagers", id);
	}
	override void registerResources(IResourceManagerRegistry resmanRegistry)
	{
		infof("%s registerResources", id);
	}
	override void preInit()
	{
		infof("%s preInit", id);
	}
	override void init(IPluginManager pluginman)
	{
		infof("%s init", id);
	}
	override void postInit()
	{
		infof("%s postInit", id);
	}
}
