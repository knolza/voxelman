/**
Copyright: Copyright (c) 2015-2016 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module packager;

import std.file;
import std.string;
import std.digest.crc;
import std.stdio;
import std.zip;
import std.path;
import std.process;
import std.datetime;

enum ROOT_PATH = "../..";
string testDir;

void main(string[] args)
{
	string semver = "0.7.0";
	testDir = buildNormalizedPath(ROOT_PATH, "test");
	if (exists(testDir))
		rmdirRecurse(testDir);

	StopWatch sw;
	sw.start();
	completeBuild(Arch.x32, semver);
	writeln;
	completeBuild(Arch.x64, semver);
	sw.stop();
	writefln("Finished in %.1fs", sw.peek().to!("seconds", real));
}

void completeBuild(Arch arch, string semver)
{
	string dub_arch = arch == Arch.x32 ? "x86" : "x86_64";
	string launcher_arch = arch == Arch.x32 ? "32" : "64";

	string dubCom(Arch arch) {
		return format(`dub run --root="tools/launcher" -q --nodeps --build=release --arch=%s -- --release=%s`,
				dub_arch, launcher_arch);
	}

	string com = dubCom(arch);
	writefln("Executing '%s'", com); stdout.flush();

	auto dub = executeShell(com, null, Config.none, size_t.max, ROOT_PATH);

	if (dub.status != 0)
		writeln("Failed to run launcher");
	dub.output.write;

	writefln("Packing %sbit", launcher_arch); stdout.flush();
	pack(semver, arch, Platform.windows);
}

struct ReleasePackage
{
	string semver;
	Arch arch;
	Platform platform;
	ZipArchive zip;
	string fileRoot;
	string archRoot;
}

void pack(string semver, Arch arch, Platform pl)
{
	ReleasePackage pack = ReleasePackage(
		semver,
		arch,
		pl,
		new ZipArchive,
		ROOT_PATH);
	string archName = archName(&pack, "voxelman");
	pack.archRoot = archName;

	makePackage(&pack);
	string archiveName = buildNormalizedPath(ROOT_PATH, archName) ~ ".zip";
	writePackage(&pack, archiveName);

	extractArchive(archiveName, testDir);
}

enum Arch { x64, x32 }
enum Platform { windows, linux, macos }
string[Platform] platformToString;
string[Arch] archToString;
static this()
{
	platformToString = [Platform.windows : "win", Platform.linux : "linux", Platform.macos : "mac"];
	archToString = [Arch.x64 : "64", Arch.x32 : "32"];
}

void makePackage(ReleasePackage* pack)
{
	pack.addFiles("builds/default", "*.exe");
	pack.addFiles("res", "*");
	pack.addFiles("config", "*.sdl");
	pack.addFiles("lib/"~archToString[pack.arch], "*.dll");
	pack.addFile("README.md");
	pack.addFile("CHANGELOG.md");
	pack.addFile("LICENSE.md");
	pack.addFile("pluginpacks/default.txt");
	pack.addFile("launcher.exe");
}

void writePackage(ReleasePackage* pack, string path)
{
	std.file.write(path, pack.zip.build());
}

string archName(R)(ReleasePackage* pack, R baseName)
{
	string arch = archToString[pack.arch];
	string platform = platformToString[pack.platform];
	return format("%s-v%s-%s%s", baseName, pack.semver, platform, arch);
}

alias normPath = buildNormalizedPath;
alias absPath = absolutePath;
void addFiles(ReleasePackage* pack, string path, string pattern)
{
	import std.file : dirEntries, SpanMode;

	string absRoot = pack.fileRoot.absPath.normPath;
	foreach (entry; dirEntries(buildPath(pack.fileRoot, path), pattern, SpanMode.depth))
	if (entry.isFile) {
		string absPath = entry.name.absPath.normPath;
		addFile(pack, absPath, relativePath(absPath, absRoot));
	}
}

void addFile(ReleasePackage* pack, string arch_name)
{
	addFile(pack.zip, buildPath(pack.fileRoot, arch_name).absPath.normPath, buildPath(pack.archRoot, arch_name));
}

void addFile(ReleasePackage* pack, string fs_name, string arch_name)
{
	addFile(pack.zip, fs_name.absPath.normPath, buildPath(pack.archRoot, arch_name));
}

void addFile(ZipArchive arch, string fs_name, string arch_name)
{
	string norm = arch_name.normPath;
	writefln("Add %s as %s", fs_name, norm);
	void[] data = std.file.read(fs_name);
	ArchiveMember am = new ArchiveMember();
	am.name = norm;
	am.compressionMethod = CompressionMethod.deflate;
	am.expandedData(cast(ubyte[])data);
	arch.addMember(am);
}

void extractArchive(string archive, string pathTo)
{
	extractArchive(new ZipArchive(std.file.read(archive)), pathTo);
}

void extractArchive(ZipArchive archive, string pathTo)
{
	foreach (ArchiveMember am; archive.directory)
	{
		string targetPath = buildPath(pathTo, am.name);
		mkdirRecurse(dirName(targetPath));
		archive.expand(am);
		std.file.write(targetPath, am.expandedData);
	}
}
